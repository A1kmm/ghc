{-# LANGUAGE RecordWildCards, GADTs #-}
module CmmLayoutStack (
       cmmLayoutStack, setInfoTableStackMap
  ) where

import StgCmmUtils      ( callerSaveVolatileRegs ) -- XXX
import StgCmmForeign    ( saveThreadState, loadThreadState ) -- XXX

import Cmm
import BlockId
import CLabel
import CmmUtils
import MkGraph
import Module
import ForeignCall
import CmmLive
import CmmProcPoint
import SMRep
import Hoopl hiding ((<*>), mkLast, mkMiddle)
import OptimizationFuel
import Constants
import UniqSupply
import Maybes
import UniqFM
import Util

import FastString
import Outputable
import Data.Map (Map)
import qualified Data.Map as Map
import qualified Data.Set as Set
import Control.Monad.Fix
import Data.Array as Array
import Data.Bits
import Data.List (nub)
import Control.Monad (liftM)

#include "HsVersions.h"


data StackSlot = Occupied | Empty
     -- Occupied: a return address or part of an update frame

instance Outputable StackSlot where
  ppr Occupied = ptext (sLit "XXX")
  ppr Empty    = ptext (sLit "---")

-- All stack locations are expressed as positive byte offsets from the
-- "base", which is defined to be the address above the return address
-- on the stack on entry to this CmmProc.
--
-- Lower addresses have higher StackLocs.
--
type StackLoc = ByteOff

{-
 A StackMap describes the stack at any given point.  At a continuation
 it has a particular layout, like this:

         |             | <- base
         |-------------|
         |     ret0    | <- base + 8
         |-------------|
         .  upd frame  . <- base + sm_ret_off
         |-------------|
         |             |
         .    vars     .
         . (live/dead) .
         |             | <- base + sm_sp - sm_args
         |-------------|
         |    ret1     |
         .  ret vals   . <- base + sm_sp    (<--- Sp points here)
         |-------------|

Why do we include the final return address (ret0) in our stack map?  I
have absolutely no idea, but it seems to be done that way consistently
in the rest of the code generator, so I played along here. --SDM

Note that we will be constructing an info table for the continuation
(ret1), which needs to describe the stack down to, but not including,
the update frame (or ret0, if there is no update frame).
-}

data StackMap = StackMap
 {  sm_sp   :: StackLoc
       -- ^ the offset of Sp relative to the base on entry
       -- to this block.
 ,  sm_args :: ByteOff
       -- ^ the number of bytes of arguments in the area for this block
       -- Defn: the offset of young(L) relative to the base is given by
       -- (sm_sp - sm_args) of the StackMap for block L.
 ,  sm_ret_off :: ByteOff
       -- ^ Number of words of stack that we do not describe with an info
       -- table, because it contains an update frame.
 ,  sm_regs :: UniqFM (LocalReg,StackLoc)
       -- ^ regs on the stack
 }

instance Outputable StackMap where
  ppr StackMap{..} =
     text "Sp = " <> int sm_sp $$
     text "sm_args = " <> int sm_args $$
     text "sm_ret_off = " <> int sm_ret_off $$
     text "sm_regs = " <> ppr (eltsUFM sm_regs)


cmmLayoutStack :: ProcPointSet -> ByteOff -> CmmGraph
               -> FuelUniqSM (CmmGraph, BlockEnv StackMap)
cmmLayoutStack procpoints entry_args
               graph@(CmmGraph { g_entry = entry })
  = do
    pprTrace "cmmLayoutStack" (ppr entry_args) $ return ()
    liveness <- cmmLiveness graph
    pprTrace "liveness" (ppr liveness) $ return ()
    let blocks = postorderDfs graph

    (final_stackmaps, final_high_sp, new_blocks) <- liftUniq $
          mfix $ \ ~(rec_stackmaps, rec_high_sp, _new_blocks) ->
            layout procpoints liveness entry entry_args
                   rec_stackmaps rec_high_sp blocks

    new_blocks' <- liftUniq $ mapM lowerSafeForeignCall new_blocks

    pprTrace ("Sp HWM") (ppr final_high_sp) $
       return (ofBlockList entry new_blocks', final_stackmaps)



layout :: BlockSet                      -- proc points
       -> BlockEnv CmmLive              -- liveness
       -> BlockId                       -- entry
       -> ByteOff                       -- stack args on entry

       -> BlockEnv StackMap             -- [final] stack maps
       -> ByteOff                       -- [final] Sp high water mark

       -> [CmmBlock]                    -- [in] blocks

       -> UniqSM
          ( BlockEnv StackMap           -- [out] stack maps
          , ByteOff                     -- [out] Sp high water mark
          , [CmmBlock]                  -- [out] new blocks
          )

layout procpoints liveness entry entry_args final_stackmaps final_hwm blocks
  = go blocks init_stackmap entry_args []
  where
    (updfr, cont_info)  = collectContInfo blocks

    init_stackmap = mapSingleton entry StackMap{ sm_sp   = entry_args
                                               , sm_args = entry_args
                                               , sm_ret_off = updfr
                                               , sm_regs = emptyUFM
                                               }

    go [] acc_stackmaps acc_hwm acc_blocks
      = return (acc_stackmaps, acc_hwm, acc_blocks)

    go (b0 : bs) acc_stackmaps acc_hwm acc_blocks
      = do
       let (entry0@(CmmEntry entry_lbl), middle0, last0) = blockSplit b0
    
       let stack0@StackMap { sm_sp = sp0 }
               = mapFindWithDefault
                     (pprPanic "no stack map for" (ppr entry_lbl))
                     entry_lbl acc_stackmaps
    
       pprTrace "layout" (ppr entry_lbl <+> ppr stack0) $ return ()
    
       -- (a) Update the stack map to include the effects of
       --     assignments in this block
       let stack1 = foldBlockNodesF (procMiddle acc_stackmaps) middle0 stack0
    
       -- (b) Insert assignments to reload all the live variables if this
       --     block is a proc point
       let middle1 = if entry_lbl `setMember` procpoints
                        then foldr blockCons middle0 (insertReloads stack0)
                        else middle0
    
       -- (c) Look at the last node and if we are making a call or
       --     jumping to a proc point, we must save the live
       --     variables, adjust Sp, and construct the StackMaps for
       --     each of the successor blocks.  See handleLastNode for
       --     details.
       (middle2, sp_off, last1, fixup_blocks, out)
           <- handleLastNode procpoints liveness cont_info
                             acc_stackmaps stack1 middle0 last0
    
       pprTrace "layout(out)" (ppr out) $ return ()

       -- (d) Manifest Sp: run over the nodes in the block and replace
       --     CmmStackSlot with CmmLoad from Sp with a concrete offset.
       --
       -- our block:
       --    middle1          -- the original middle nodes
       --    middle2          -- live variable saves from handleLastNode
       --    Sp = Sp + sp_off -- Sp adjustment goes here
       --    last1            -- the last node
       --
       let middle_pre = blockToList $ foldl blockSnoc middle1 middle2

           sp_high = final_hwm - entry_args
              -- The stack check value is adjusted by the Sp offset on
              -- entry to the proc, which is entry_args.  We are
              -- assuming that we only do a stack check at the
              -- beginning of a proc, and we don't modify Sp before the
              -- check.

           final_blocks = manifestSp final_stackmaps stack0 sp0 sp_high entry0
                              middle_pre sp_off last1 fixup_blocks

           acc_stackmaps' = mapUnion acc_stackmaps out

           hwm' = maximum (acc_hwm : (sp0 - sp_off) : map sm_sp (mapElems out))

       go bs acc_stackmaps' hwm' (final_blocks ++ acc_blocks)


-- -----------------------------------------------------------------------------

-- This doesn't seem right somehow.  We need to find out whether this
-- proc will push some update frame material at some point, so that we
-- can avoid using that area of the stack for spilling.  The
-- updfr_space field of the CmmProc *should* tell us, but it doesn't
-- (I think maybe it gets filled in later when we do proc-point
-- splitting).
--
-- So we'll just take the max of all the cml_ret_offs.  This could be
-- unnecessarily pessimistic, but probably not in the code we
-- generate.

collectContInfo :: [CmmBlock] -> (ByteOff, BlockEnv ByteOff)
collectContInfo blocks
  = (maximum ret_offs, mapFromList (catMaybes mb_argss))
 where
  (mb_argss, ret_offs) = mapAndUnzip get_cont blocks

  get_cont b =
     case lastNode b of
        CmmCall { cml_cont = Just l, .. }
           -> (Just (l, cml_ret_args), cml_ret_off)
        CmmForeignCall { .. }
           -> (Just (succ, 0), updfr) -- ??
        _other -> (Nothing, 0)


-- -----------------------------------------------------------------------------
-- Updating the StackMap from middle nodes

-- Look for loads from stack slots, and update the StackMap.  This is
-- purelyu for optimisation reasons, so that we can avoid saving a
-- variable back to a different stack slot if it is already on the
-- stack.
--
-- This happens a lot: for example when function arguments are passed
-- on the stack and need to be immediately saved across a call, we
-- want to just leave them where they are on the stack.
--
procMiddle :: BlockEnv StackMap -> CmmNode e x -> StackMap -> StackMap
procMiddle stackmaps node sm
  = case node of
     CmmAssign (CmmLocal r) (CmmLoad (CmmStackSlot area off) _)
       -> sm { sm_regs = addToUFM (sm_regs sm) r (r,loc) }
        where loc = getStackLoc area off stackmaps
     CmmAssign (CmmLocal r) _other
       -> sm { sm_regs = delFromUFM (sm_regs sm) r }
     _other
       -> sm

getStackLoc :: Area -> ByteOff -> BlockEnv StackMap -> StackLoc
getStackLoc Old       n _         = n
getStackLoc (Young l) n stackmaps =
  case mapLookup l stackmaps of
    Nothing -> pprPanic "getStackLoc" (ppr l)
    Just sm -> sm_sp sm - sm_args sm + n


-- -----------------------------------------------------------------------------
-- Handling stack allocation for a last node

-- We take a single last node and turn it into:
--
--    C1 (some statements)
--    Sp = Sp + N
--    C2 (some more statements)
--    call f()          -- the actual last node
--
-- plus possibly some more blocks (we may have to add some fixup code
-- between the last node and the continuation).
--
-- C1: is the code for saving the variables across this last node onto
-- the stack, if the continuation is a call or jumps to a proc point.
--
-- C2: if the last node is a safe foreign call, we have to inject some
-- extra code that goes *after* the Sp adjustment.

handleLastNode
   :: ProcPointSet -> BlockEnv CmmLive -> BlockEnv ByteOff
   -> BlockEnv StackMap -> StackMap
   -> Block CmmNode O O
   -> CmmNode O C
   -> UniqSM
      ( [CmmNode O O]      -- nodes to go *before* the Sp adjustment
      , ByteOff            -- amount to adjust Sp
      , CmmNode O C        -- new last node
      , [CmmBlock]         -- new blocks
      , BlockEnv StackMap  -- stackmaps for the continuations
      )

handleLastNode procpoints liveness cont_info stackmaps
               stack0@StackMap { sm_sp = sp0 } middle last
 = case last of
    --  At each return / tail call,
    --  adjust Sp to point to the last argument pushed, which
    --  is cml_args, after popping any other junk from the stack.
    CmmCall{ cml_cont = Nothing, .. } -> do
      let sp_off = sp0 - cml_args
      return ([], sp_off, last, [], mapEmpty)

    --  At each CmmCall with a continuation:
    CmmCall{ cml_cont = Just cont_lbl, .. } ->
       return $ lastCall cont_lbl cml_args cml_ret_args cml_ret_off

    CmmForeignCall{ succ = cont_lbl, .. } -> do
       return $ lastCall cont_lbl wORD_SIZE wORD_SIZE (sm_ret_off stack0)
            -- one word each for args and results: the return address

    CmmBranch{..}     ->  handleProcPoints
    CmmCondBranch{..} ->  handleProcPoints
    CmmSwitch{..}     ->  handleProcPoints

  where
     -- Calls and ForeignCalls are handled the same way:
     lastCall :: BlockId -> ByteOff -> ByteOff -> ByteOff
              -> ( [CmmNode O O]
                 , ByteOff
                 , CmmNode O C
                 , [CmmBlock]
                 , BlockEnv StackMap
                 )
     lastCall lbl cml_args cml_ret_args cml_ret_off
      =  ( assignments
         , spOffsetForCall sp0 cont_stack cml_args
         , last
         , [] -- no new blocks
         , cont_stacks )
      where
         (assignments, cont_stack, cont_stacks)
           | Just cont_stack <- mapLookup lbl stackmaps
                 -- If we have already seen this continuation before, then
                 -- we just have to make the stack look the same:
           = (fixupStack stack0 cont_stack, cont_stack, mapEmpty)
                 -- Otherwise, we have to allocate the stack frame
           | otherwise
           = (save_assignments, new_cont_stack, mapSingleton lbl new_cont_stack)
           where
            (new_cont_stack, save_assignments)
               = setupStackFrame lbl liveness cml_ret_off cml_ret_args stack0

     -- For other last nodes (branches), if any of the targets is a
     -- proc point, we have to set up the stack to match what the proc
     -- point is expecting.
     --
     handleProcPoints :: UniqSM ( [CmmNode O O]
                                , ByteOff
                                , CmmNode O C
                                , [CmmBlock]
                                , BlockEnv StackMap )

     handleProcPoints
       | let future_continuation = foldBlockNodesB f middle Nothing
                where f (CmmStore (CmmStackSlot (Young l) _) (CmmLit (CmmBlock _))) _
                         = Just l
                      f _ r = r
       , Just l <- future_continuation
       , (nub $ filter (`setMember` procpoints) $ successors last) == [l]
       , pprTrace "special" (ppr l) False
       = undefined
--       do
--         (assigs, sp_off, _, _, out) <-
--              lastCall l [] args ret_args ret_off

        | otherwise = do
          pps <- mapM handleProcPoint (successors last)
          let lbl_map :: LabelMap Label
              lbl_map = mapFromList [ (l,tmp) | (l,tmp,_,_) <- pps ]
              fix_lbl l = mapLookup l lbl_map `orElse` l
          return ( []
                 , 0
                 , mapSuccessors fix_lbl last
                 , concat [ blk | (_,_,_,blk) <- pps ]
                 , mapFromList [ (l, sm) | (l,_,sm,_) <- pps ] )

     -- For each proc point that is a successor of this block
     --   (a) if the proc point already has a stackmap, we need to
     --       shuffle the current stack to make it look the same.
     --       We have to insert a new block to make this happen.
     --   (b) otherwise, call "allocate live stack0" to make the
     --       stack map for the proc point
     handleProcPoint :: BlockId
                     -> UniqSM (BlockId, BlockId, StackMap, [CmmBlock])
     handleProcPoint l
        | not (l `setMember` procpoints) = return (l, l, stack0, [])
        | otherwise = do
           tmp_lbl <- liftM mkBlockId $ getUniqueM
           let
               (stack2, assigs) =
                  case mapLookup l stackmaps of
                    Just pp_sm -> (pp_sm, fixupStack stack0 pp_sm)
                    Nothing    ->
                      pprTrace "first visit to proc point"
                                   (ppr l <+> ppr stack1) $
                      (stack1, assigs)
                      where
                       cont_args = mapFindWithDefault 0 l cont_info
                       (stack1, assigs) =
                           setupStackFrame l liveness (sm_ret_off stack0)
                                                       cont_args stack0

               sp_off = sp0 - sm_sp stack2

               block = blockJoin (CmmEntry tmp_lbl)
                                 (maybeAddSpAdj sp_off (blockFromList assigs))
                                 (CmmBranch l)
           --
           return (l, tmp_lbl, stack2, [block])


  
-- Sp is currently pointing to current_sp,
-- we want it to point to
--    (sm_sp cont_stack - sm_args cont_stack + args)
-- so the difference is
--    sp0 - (sm_sp cont_stack - sm_args cont_stack + args)
spOffsetForCall :: ByteOff -> StackMap -> ByteOff -> ByteOff
spOffsetForCall current_sp cont_stack args
  = current_sp - (sm_sp cont_stack - sm_args cont_stack + args)


-- | create a sequence of assignments to establish the new StackMap,
-- given the old StackMap.
fixupStack :: StackMap -> StackMap -> [CmmNode O O]
fixupStack old_stack new_stack = concatMap move new_locs
 where
     old_map :: Map LocalReg ByteOff
     old_map  = Map.fromList (stackSlotRegs old_stack)
     new_locs = stackSlotRegs new_stack

     move (r,n)
       | Just m <- Map.lookup r old_map, n == m = []
       | otherwise = [CmmStore (CmmStackSlot Old n)
                               (CmmReg (CmmLocal r))]



setupStackFrame
             :: BlockId                 -- label of continuation
             -> BlockEnv CmmLive        -- liveness
             -> ByteOff      -- updfr
             -> ByteOff      -- bytes of return values on stack
             -> StackMap     -- current StackMap
             -> (StackMap, [CmmNode O O])

setupStackFrame lbl liveness updfr_off ret_args stack0
  = (cont_stack, assigs)
  where
      -- get the set of LocalRegs live in the continuation
      live = mapFindWithDefault Set.empty lbl liveness

      -- the stack from the base to updfr_off is off-limits.
      -- our new stack frame contains:
      --   * saved live variables
      --   * the return address [young(C) + 8]
      --   * the args for the call,
      --     which are replaced by the return values at the return
      --     point.

      -- everything up to updfr_off is off-limits
      -- stack1 contains updfr_off, plus everything we need to save
      (stack1, assigs) = allocate updfr_off live stack0

      -- And the Sp at the continuation is:
      --   sm_sp stack1 + ret_args
      cont_stack = stack1{ sm_sp = sm_sp stack1 + ret_args
                         , sm_args = ret_args
                         , sm_ret_off = updfr_off
                         }


-- -----------------------------------------------------------------------------
-- Manifesting Sp

-- | Manifest Sp: turn all the CmmStackSlots into CmmLoads from Sp.  The
-- block looks like this:
--
--    middle_pre       -- the middle nodes
--    Sp = Sp + sp_off -- Sp adjustment goes here
--    last             -- the last node
--
-- And we have some extra blocks too (that don't contain Sp adjustments)
--
-- The adjustment for middle_pre will be different from that for
-- middle_post, because the Sp adjustment intervenes.
--
manifestSp
   :: BlockEnv StackMap  -- StackMaps for other blocks
   -> StackMap           -- StackMap for this block
   -> ByteOff            -- Sp on entry to the block
   -> ByteOff            -- SpHigh
   -> CmmNode C O        -- first node
   -> [CmmNode O O]      -- middle
   -> ByteOff            -- sp_off
   -> CmmNode O C        -- last node
   -> [CmmBlock]         -- new blocks
   -> [CmmBlock]         -- final blocks with Sp manifest

manifestSp stackmaps stack0 sp0 sp_high
           first middle_pre sp_off last fixup_blocks
  = final_block : fixup_blocks'
  where
    area_off = getAreaOff stackmaps

    adj_pre_sp, adj_post_sp :: CmmNode e x -> CmmNode e x
    adj_pre_sp  = mapExpDeep (areaToSp sp0            sp_high area_off)
    adj_post_sp = mapExpDeep (areaToSp (sp0 - sp_off) sp_high area_off)

    final_middle = maybeAddSpAdj sp_off $
                   blockFromList $
                   map adj_pre_sp $
                   elimStackStores stack0 stackmaps area_off $
                   middle_pre

    final_last    = optStackCheck (adj_post_sp last)

    final_block   = blockJoin first final_middle final_last

    fixup_blocks' = map (blockMapNodes3 (id, adj_post_sp, id)) fixup_blocks


getAreaOff :: BlockEnv StackMap -> (Area -> StackLoc)
getAreaOff _ Old = 0
getAreaOff stackmaps (Young l) =
  case mapLookup l stackmaps of
    Just sm -> sm_sp sm - sm_args sm
    Nothing -> pprPanic "getAreaOff" (ppr l)


maybeAddSpAdj :: ByteOff -> Block CmmNode O O -> Block CmmNode O O
maybeAddSpAdj 0      block = block
maybeAddSpAdj sp_off block
   = block `blockSnoc` CmmAssign spReg (cmmOffset (CmmReg spReg) sp_off)


{-
Sp(L) is the Sp offset on entry to block L relative to the base of the
OLD area.

SpArgs(L) is the size of the young area for L, i.e. the number of
arguments.

 - in block L, each reference to [old + N] turns into
   [Sp + Sp(L) - N]

 - in block L, each reference to [young(L') + N] turns into
   [Sp + Sp(L) - Sp(L') + SpArgs(L') - N]

 - be careful with the last node of each block: Sp has already been adjusted
   to be Sp + Sp(L) - Sp(L')
-}

areaToSp :: ByteOff -> ByteOff -> (Area -> StackLoc) -> CmmExpr -> CmmExpr
areaToSp sp_old _sp_hwm area_off (CmmStackSlot area n) =
  cmmOffset (CmmReg spReg) (sp_old - area_off area - n)
areaToSp _ sp_hwm _ (CmmLit CmmHighStackMark) = CmmLit (mkIntCLit sp_hwm)
areaToSp _ _ _ (CmmMachOp (MO_U_Lt _)  -- Note [null stack check]
                      [CmmMachOp (MO_Sub _)
                              [ CmmReg (CmmGlobal Sp)
                              , CmmLit (CmmInt 0 _)],
                       CmmReg (CmmGlobal SpLim)]) = CmmLit (CmmInt 0 wordWidth)
areaToSp _ _ _ other = other

-- -----------------------------------------------------------------------------
-- Note [null stack check]
--
-- If the high-water Sp is zero, then we end up with
--
--   if (Sp - 0 < SpLim) then .. else ..
--
-- and possibly some dead code for the failure case.  Optimising this
-- away depends on knowing that SpLim <= Sp, so it is really the job
-- of the stack layout algorithm, hence we do it now.  This is also
-- convenient because control-flow optimisation later will drop the
-- dead code.

optStackCheck :: CmmNode O C -> CmmNode O C
optStackCheck n = -- Note [null stack check]
 case n of
   CmmCondBranch (CmmLit (CmmInt 0 _)) _true false -> CmmBranch false
   other -> other

-- -----------------------------------------------------------------------------
-- Saving live registers

-- | Given a set of live registers and a StackMap, save all the registers
-- on the stack and return the new StackMap and the assignments to do
-- the saving.
--
allocate :: ByteOff -> RegSet -> StackMap -> (StackMap, [CmmNode O O])
allocate ret_off live stackmap@StackMap{ sm_sp = sp0
                                       , sm_regs = regs0 }
 =
  pprTrace "allocate" (ppr live $$ ppr stackmap) $

   -- we only have to save regs that are not already in a slot
   let to_save = filter (not . (`elemUFM` regs0)) (Set.elems live)
       regs1   = filterUFM (\(r,_) -> elemRegSet r live) regs0
   in

   -- make a map of the stack
   let stack = reverse $ Array.elems $
               accumArray (\_ x -> x) Empty (1, toWords (max sp0 ret_off)) $
                 ret_words ++ live_words
            where ret_words =
                   [ (x, Occupied)
                   | x <- [ 1 .. toWords ret_off] ]
                  live_words =
                   [ (toWords x, Occupied)
                   | (r,off) <- eltsUFM regs1,
                     let w = localRegBytes r,
                     x <- [ off, off-wORD_SIZE .. off - w + 1] ]
   in

   -- Pass over the stack: find slots to save all the new live variables,
   -- choosing the oldest slots first (hence a foldr).
   let
       save slot ([], stack, n, assigs, regs) -- no more regs to save
          = ([], slot:stack, n `plusW` 1, assigs, regs)
       save slot (to_save, stack, n, assigs, regs)
          = case slot of
               Occupied ->  (to_save, Occupied:stack, n `plusW` 1, assigs, regs)
               Empty
                 | Just (stack', r, to_save') <-
                       select_save to_save (slot:stack)
                 -> let assig = CmmStore (CmmStackSlot Old n')
                                         (CmmReg (CmmLocal r))
                        n' = n `plusW` 1
                   in
                        (to_save', stack', n', assig : assigs, (r,(r,n')):regs)

                 | otherwise
                 -> (to_save, slot:stack, n `plusW` 1, assigs, regs)

       -- we should do better here: right now we'll fit the smallest first,
       -- but it would make more sense to fit the biggest first.
       select_save :: [LocalReg] -> [StackSlot]
                   -> Maybe ([StackSlot], LocalReg, [LocalReg])
       select_save regs stack = go regs []
         where go []     _no_fit = Nothing
               go (r:rs) no_fit
                 | Just rest <- dropEmpty words stack
                 = Just (replicate words Occupied ++ rest, r, rs++no_fit)
                 | otherwise
                 = go rs (r:no_fit)
                 where words = localRegWords r

       -- fill in empty slots as much as possible
       (still_to_save, save_stack, n, save_assigs, save_regs)
          = foldr save (to_save, [], 0, [], []) stack

       -- push any remaining live vars on the stack
       (push_sp, push_assigs, push_regs)
          = foldr push (n, [], []) still_to_save
          where
              push r (n, assigs, regs)
                = (n', assig : assigs, (r,(r,n')) : regs)
                where
                  n' = n + localRegBytes r
                  assig = CmmStore (CmmStackSlot Old n')
                                   (CmmReg (CmmLocal r))

       trim_sp
          | not (null push_regs) = push_sp
          | otherwise
          = n `plusW` (- length (takeWhile isEmpty save_stack))

       final_regs = regs1 `addListToUFM` push_regs
                          `addListToUFM` save_regs

   in
  -- XXX should be an assert
   if ( n /= max sp0 ret_off ) then pprPanic "allocate" (ppr n <+> ppr sp0 <+> ppr ret_off) else

   if (trim_sp .&. (wORD_SIZE - 1)) /= 0  then pprPanic "allocate2" (ppr trim_sp <+> ppr final_regs <+> ppr push_sp) else

   ( stackmap { sm_regs = final_regs , sm_sp = trim_sp }
   , push_assigs ++ save_assigs )


-- -----------------------------------------------------------------------------

-- | Eliminate stores of the form
--
--    Sp[area+n] = r
--
-- when we know that r is already in the same slot as Sp[area+n].  We
-- could do this in a later optimisation pass, but that would involve
-- a separate analysis and we already have the information to hand
-- here.  It helps clean up some extra stack stores in common cases.
--
-- Note that we may have to modify the StackMap as we walk through the
-- code using procMiddle, since an assignment to a variable in the
-- StackMap will invalidate its mapping there.
--
elimStackStores :: StackMap
                -> BlockEnv StackMap
                -> (Area -> ByteOff)
                -> [CmmNode O O]
                -> [CmmNode O O]
elimStackStores stackmap stackmaps area_off nodes
  = go stackmap nodes
  where
    go _stackmap [] = []
    go stackmap (n:ns)
     = case n of
         CmmStore (CmmStackSlot area m) (CmmReg (CmmLocal r))
            | Just (_,off) <- lookupUFM (sm_regs stackmap) r
            , area_off area + m == off
            -> pprTrace "eliminated a node!" (ppr r) $ go stackmap ns
         _otherwise
            -> n : go (procMiddle stackmaps n stackmap) ns


-- -----------------------------------------------------------------------------
-- Update info tables to include stack liveness


setInfoTableStackMap :: BlockEnv StackMap -> CmmDecl -> CmmDecl
setInfoTableStackMap stackmaps
    (CmmProc top_info@TopInfo{..} l g@CmmGraph{g_entry = eid})
  = CmmProc top_info{ info_tbl = fix_info info_tbl } l g
  where
    fix_info info_tbl@CmmInfoTable{ cit_rep = StackRep _ } =
       info_tbl { cit_rep = StackRep (get_liveness eid) }
    fix_info other = other

    get_liveness :: BlockId -> Liveness
    get_liveness lbl
      = case mapLookup lbl stackmaps of
          Nothing -> pprPanic "setInfoTableStackMap" (ppr lbl)
          Just sm -> stackMapToLiveness sm

setInfoTableStackMap _ d = d


stackMapToLiveness :: StackMap -> Liveness
stackMapToLiveness StackMap{..} =
   reverse $ Array.elems $
        accumArray (\_ x -> x) True (toWords sm_ret_off + 1,
                                     toWords (sm_sp - sm_args)) live_words
   where
     live_words =  [ (toWords off, False)
                   | (r,off) <- eltsUFM sm_regs, isGcPtrType (localRegType r) ]


-- -----------------------------------------------------------------------------
-- Lowering safe foreign calls

{-
Note [lower safe foreign calls]

We start with

   Sp[young(L1)] = L1
 ,-----------------------
 | r1 = foo(x,y,z) returns to L1
 '-----------------------
 L1:
   R1 = r1 -- copyIn, inserted by mkSafeCall
   ...

the stack layout algorithm will arrange to save and reload everything
live across the call.  Our job now is to expand the call so we get

   Sp[young(L1)] = L1
 ,-----------------------
 | SAVE_THREAD_STATE()
 | token = suspendThread(BaseReg, interruptible)
 | r = foo(x,y,z)
 | BaseReg = resumeThread(token)
 | LOAD_THREAD_STATE()
 | R1 = r  -- copyOut
 | jump L1
 '-----------------------
 L1:
   r = R1 -- copyIn, inserted by mkSafeCall
   ...

Note the copyOut, which saves the results in the places that L1 is
expecting them (see Note {safe foreign call convention]).
-}

lowerSafeForeignCall :: CmmBlock -> UniqSM CmmBlock
lowerSafeForeignCall block
  | (entry, middle, CmmForeignCall { .. }) <- blockSplit block
  = do
    -- Both 'id' and 'new_base' are KindNonPtr because they're
    -- RTS-only objects and are not subject to garbage collection
    id <- newTemp bWord
    new_base <- newTemp (cmmRegType (CmmGlobal BaseReg))
    let (caller_save, caller_load) = callerSaveVolatileRegs
    load_tso <- newTemp gcWord
    load_stack <- newTemp gcWord
    let suspend = saveThreadState <*>
                  caller_save <*>
                  mkMiddle (callSuspendThread id intrbl)
        midCall = mkUnsafeCall tgt res args
        resume  = mkMiddle (callResumeThread new_base id) <*>
                  -- Assign the result to BaseReg: we
                  -- might now have a different Capability!
                  mkAssign (CmmGlobal BaseReg) (CmmReg (CmmLocal new_base)) <*>
                  caller_load <*>
                  loadThreadState load_tso load_stack
        -- Note: The successor must be a procpoint, and we have already split,
        --       so we use a jump, not a branch.
        succLbl = CmmLit (CmmLabel (infoTblLbl succ))

        (ret_args, copyout) = copyOutOflow NativeReturn Jump (Young succ)
                                           (map (CmmReg . CmmLocal) res)
                                           updfr (0, [])

        jump = CmmCall { cml_target   = succLbl
                       , cml_cont     = Just succ
                       , cml_args     = widthInBytes wordWidth
                       , cml_ret_args = ret_args
                       , cml_ret_off  = updfr }

    graph' <- lgraphOfAGraph $ suspend <*>
                               midCall <*>
                               resume  <*>
                               copyout <*>
                               mkLast jump

    case toBlockList graph' of
      [one] -> let (_, middle', last) = blockSplit one
               in return (blockJoin entry (middle `blockAppend` middle') last)
      _ -> panic "lowerSafeForeignCall0"

  -- Block doesn't end in a safe foreign call:
  | otherwise = return block


foreignLbl :: FastString -> CmmExpr
foreignLbl name = CmmLit (CmmLabel (mkCmmCodeLabel rtsPackageId name))

newTemp :: CmmType -> UniqSM LocalReg
newTemp rep = getUniqueM >>= \u -> return (LocalReg u rep)

callSuspendThread :: LocalReg -> Bool -> CmmNode O O
callSuspendThread id intrbl =
  CmmUnsafeForeignCall
       (ForeignTarget (foreignLbl (fsLit "suspendThread"))
             (ForeignConvention CCallConv [AddrHint, NoHint] [AddrHint]))
       [id] [CmmReg (CmmGlobal BaseReg), CmmLit (mkIntCLit (fromEnum intrbl))]

callResumeThread :: LocalReg -> LocalReg -> CmmNode O O
callResumeThread new_base id =
  CmmUnsafeForeignCall
       (ForeignTarget (foreignLbl (fsLit "resumeThread"))
            (ForeignConvention CCallConv [AddrHint] [AddrHint]))
       [new_base] [CmmReg (CmmLocal id)]

-- -----------------------------------------------------------------------------

plusW :: ByteOff -> WordOff -> ByteOff
plusW b w = b + w * wORD_SIZE

dropEmpty :: WordOff -> [StackSlot] -> Maybe [StackSlot]
dropEmpty 0 ss           = Just ss
dropEmpty n (Empty : ss) = dropEmpty (n-1) ss
dropEmpty _ _            = Nothing

isEmpty :: StackSlot -> Bool
isEmpty Empty = True
isEmpty _ = False

localRegBytes :: LocalReg -> ByteOff
localRegBytes r = roundUpToWords (widthInBytes (typeWidth (localRegType r)))

localRegWords :: LocalReg -> WordOff
localRegWords = toWords . localRegBytes

toWords :: ByteOff -> WordOff
toWords x = x `quot` wORD_SIZE


insertReloads :: StackMap -> [CmmNode O O]
insertReloads stackmap =
   [ CmmAssign (CmmLocal r) (CmmLoad (CmmStackSlot Old sp)
                                     (localRegType r))
   | (r,sp) <- stackSlotRegs stackmap
   ]


stackSlotRegs :: StackMap -> [(LocalReg, StackLoc)]
stackSlotRegs sm = eltsUFM (sm_regs sm)