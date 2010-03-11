/* ---------------------------------------------------------------------------
 *
 * (c) The GHC Team, 1998-2006
 *
 * Asynchronous exceptions
 *
 * --------------------------------------------------------------------------*/

#include "PosixSource.h"
#include "Rts.h"

#include "sm/Storage.h"
#include "Threads.h"
#include "Trace.h"
#include "RaiseAsync.h"
#include "Schedule.h"
#include "Updates.h"
#include "STM.h"
#include "sm/Sanity.h"
#include "Profiling.h"
#if defined(mingw32_HOST_OS)
#include "win32/IOManager.h"
#endif

static void raiseAsync (Capability *cap,
			StgTSO *tso,
			StgClosure *exception, 
			rtsBool stop_at_atomically,
			StgUpdateFrame *stop_here);

static void removeFromQueues(Capability *cap, StgTSO *tso);

static void blockedThrowTo (Capability *cap, 
                            StgTSO *target, MessageThrowTo *msg);

static void throwToSendMsg (Capability *cap USED_IF_THREADS,
                            Capability *target_cap USED_IF_THREADS, 
                            MessageThrowTo *msg USED_IF_THREADS);

static void performBlockedException (Capability *cap, MessageThrowTo *msg);

/* -----------------------------------------------------------------------------
   throwToSingleThreaded

   This version of throwTo is safe to use if and only if one of the
   following holds:
   
     - !THREADED_RTS

     - all the other threads in the system are stopped (eg. during GC).

     - we surely own the target TSO (eg. we just took it from the
       run queue of the current capability, or we are running it).

   It doesn't cater for blocking the source thread until the exception
   has been raised.
   -------------------------------------------------------------------------- */

void
throwToSingleThreaded(Capability *cap, StgTSO *tso, StgClosure *exception)
{
    throwToSingleThreaded_(cap, tso, exception, rtsFalse);
}

void
throwToSingleThreaded_(Capability *cap, StgTSO *tso, StgClosure *exception, 
		       rtsBool stop_at_atomically)
{
    // Thread already dead?
    if (tso->what_next == ThreadComplete || tso->what_next == ThreadKilled) {
	return;
    }

    // Remove it from any blocking queues
    removeFromQueues(cap,tso);

    raiseAsync(cap, tso, exception, stop_at_atomically, NULL);
}

void
suspendComputation(Capability *cap, StgTSO *tso, StgUpdateFrame *stop_here)
{
    // Thread already dead?
    if (tso->what_next == ThreadComplete || tso->what_next == ThreadKilled) {
	return;
    }

    // Remove it from any blocking queues
    removeFromQueues(cap,tso);

    raiseAsync(cap, tso, NULL, rtsFalse, stop_here);
}

/* -----------------------------------------------------------------------------
   throwTo

   This function may be used to throw an exception from one thread to
   another, during the course of normal execution.  This is a tricky
   task: the target thread might be running on another CPU, or it
   may be blocked and could be woken up at any point by another CPU.
   We have some delicate synchronisation to do.

   The underlying scheme when multiple Capabilities are in use is
   message passing: when the target of a throwTo is on another
   Capability, we send a message (a MessageThrowTo closure) to that
   Capability.

   If the throwTo needs to block because the target TSO is masking
   exceptions (the TSO_BLOCKEX flag), then the message is placed on
   the blocked_exceptions queue attached to the target TSO.  When the
   target TSO enters the unmasked state again, it must check the
   queue.  The blocked_exceptions queue is not locked; only the
   Capability owning the TSO may modify it.

   To make things simpler for throwTo, we always create the message
   first before deciding what to do.  The message may get sent, or it
   may get attached to a TSO's blocked_exceptions queue, or the
   exception may get thrown immediately and the message dropped,
   depending on the current state of the target.

   Currently we send a message if the target belongs to another
   Capability, and it is

     - NotBlocked, BlockedOnMsgWakeup, BlockedOnMsgThrowTo,
       BlockedOnCCall

     - or it is masking exceptions (TSO_BLOCKEX)

   Currently, if the target is BlockedOnMVar, BlockedOnSTM, or
   BlockedOnBlackHole then we acquire ownership of the TSO by locking
   its parent container (e.g. the MVar) and then raise the exception.
   We might change these cases to be more message-passing-like in the
   future.
  
   Returns: 

   NULL               exception was raised, ok to continue

   MessageThrowTo *   exception was not raised; the source TSO
                      should now put itself in the state 
                      BlockedOnMsgThrowTo, and when it is ready
                      it should unlock the mssage using
                      unlockClosure(msg, &stg_MSG_THROWTO_info);
                      If it decides not to raise the exception after
                      all, it can revoke it safely with
                      unlockClosure(msg, &stg_IND_info);

   -------------------------------------------------------------------------- */

MessageThrowTo *
throwTo (Capability *cap,	// the Capability we hold 
	 StgTSO *source,	// the TSO sending the exception (or NULL)
	 StgTSO *target,        // the TSO receiving the exception
	 StgClosure *exception) // the exception closure
{
    MessageThrowTo *msg;

    msg = (MessageThrowTo *) allocate(cap, sizeofW(MessageThrowTo));
    // message starts locked; the caller has to unlock it when it is
    // ready.
    msg->header.info = &stg_WHITEHOLE_info;
    msg->source      = source;
    msg->target      = target;
    msg->exception   = exception;

    switch (throwToMsg(cap, msg))
    {
    case THROWTO_SUCCESS:
        return NULL;
    case THROWTO_BLOCKED:
    default:
        return msg;
    }
}
    

nat
throwToMsg (Capability *cap, MessageThrowTo *msg)
{
    StgWord status;
    StgTSO *target = msg->target;

    ASSERT(target != END_TSO_QUEUE);

    // follow ThreadRelocated links in the target first
    while (target->what_next == ThreadRelocated) {
	target = target->_link;
	// No, it might be a WHITEHOLE:
	// ASSERT(get_itbl(target)->type == TSO);
    }

    debugTraceCap(DEBUG_sched, cap,
                  "throwTo: from thread %lu to thread %lu",
                  (unsigned long)msg->source->id, 
                  (unsigned long)msg->target->id);

#ifdef DEBUG
    traceThreadStatus(DEBUG_sched, target);
#endif

    goto check_target;
retry:
    write_barrier();
    debugTrace(DEBUG_sched, "throwTo: retrying...");

check_target:
    ASSERT(target != END_TSO_QUEUE);

    // Thread already dead?
    if (target->what_next == ThreadComplete 
	|| target->what_next == ThreadKilled) {
	return THROWTO_SUCCESS;
    }

    status = target->why_blocked;
    
    switch (status) {
    case NotBlocked:
    case BlockedOnMsgWakeup:
	/* if status==NotBlocked, and target->cap == cap, then
	   we own this TSO and can raise the exception.
	   
	   How do we establish this condition?  Very carefully.

	   Let 
	       P = (status == NotBlocked)
	       Q = (tso->cap == cap)
	       
	   Now, if P & Q are true, then the TSO is locked and owned by
	   this capability.  No other OS thread can steal it.

	   If P==0 and Q==1: the TSO is blocked, but attached to this
	   capabilty, and it can be stolen by another capability.
	   
	   If P==1 and Q==0: the TSO is runnable on another
	   capability.  At any time, the TSO may change from runnable
	   to blocked and vice versa, while it remains owned by
	   another capability.

	   Suppose we test like this:

	      p = P
	      q = Q
	      if (p && q) ...

	    this is defeated by another capability stealing a blocked
	    TSO from us to wake it up (Schedule.c:unblockOne()).  The
	    other thread is doing

	      Q = 0
	      P = 1

	    assuming arbitrary reordering, we could see this
	    interleaving:

	      start: P==0 && Q==1 
	      P = 1
	      p = P
	      q = Q
	      Q = 0
	      if (p && q) ...
	       
	    so we need a memory barrier:

	      p = P
	      mb()
	      q = Q
	      if (p && q) ...

	    this avoids the problematic case.  There are other cases
	    to consider, but this is the tricky one.

	    Note that we must be sure that unblockOne() does the
	    writes in the correct order: Q before P.  The memory
	    barrier ensures that if we have seen the write to P, we
	    have also seen the write to Q.
	*/
    {
	Capability *target_cap;

	write_barrier();
	target_cap = target->cap;
	if (target_cap != cap) {
            throwToSendMsg(cap, target_cap, msg);
            return THROWTO_BLOCKED;
        } else {
            if ((target->flags & TSO_BLOCKEX) == 0) {
                // It's on our run queue and not blocking exceptions
                raiseAsync(cap, target, msg->exception, rtsFalse, NULL);
                return THROWTO_SUCCESS;
            } else {
                blockedThrowTo(cap,target,msg);
                return THROWTO_BLOCKED;
            }
        }
    }

    case BlockedOnMsgThrowTo:
    {
        Capability *target_cap;
        const StgInfoTable *i;
        MessageThrowTo *m;

        m = target->block_info.throwto;

        // target is local to this cap, but has sent a throwto
        // message to another cap.
        //
        // The source message is locked.  We need to revoke the
        // target's message so that we can raise the exception, so
        // we attempt to lock it.

        // There's a possibility of a deadlock if two threads are both
        // trying to throwTo each other (or more generally, a cycle of
        // threads).  To break the symmetry we compare the addresses
        // of the MessageThrowTo objects, and the one for which m <
        // msg gets to spin, while the other can only try to lock
        // once, but must then back off and unlock both before trying
        // again.
        if (m < msg) {
            i = lockClosure((StgClosure *)m);
        } else {
            i = tryLockClosure((StgClosure *)m);
            if (i == NULL) {
//            debugBelch("collision\n");
                throwToSendMsg(cap, target->cap, msg);
                return THROWTO_BLOCKED;
            }
        }

        if (i != &stg_MSG_THROWTO_info) {
            // if it's an IND, this TSO has been woken up by another Cap
            unlockClosure((StgClosure*)m, i);
            goto retry;
        }

        target_cap = target->cap;
        if (target_cap != cap) {
            unlockClosure((StgClosure*)m, i);
            throwToSendMsg(cap, target_cap, msg);
            return THROWTO_BLOCKED;
        }

	if ((target->flags & TSO_BLOCKEX) &&
	    ((target->flags & TSO_INTERRUPTIBLE) == 0)) {
            unlockClosure((StgClosure*)m, i);
            blockedThrowTo(cap,target,msg);
            return THROWTO_BLOCKED;
        }

        // nobody else can wake up this TSO after we claim the message
        unlockClosure((StgClosure*)m, &stg_IND_info);

        raiseAsync(cap, target, msg->exception, rtsFalse, NULL);
        unblockOne(cap, target);
        return THROWTO_SUCCESS;
    }

    case BlockedOnMVar:
    {
	/*
	  To establish ownership of this TSO, we need to acquire a
	  lock on the MVar that it is blocked on.
	*/
	StgMVar *mvar;
	StgInfoTable *info USED_IF_THREADS;
	
	mvar = (StgMVar *)target->block_info.closure;

	// ASSUMPTION: tso->block_info must always point to a
	// closure.  In the threaded RTS it does.
        switch (get_itbl(mvar)->type) {
        case MVAR_CLEAN:
        case MVAR_DIRTY:
            break;
        default:
            goto retry;
        }

	info = lockClosure((StgClosure *)mvar);

	if (target->what_next == ThreadRelocated) {
	    target = target->_link;
	    unlockClosure((StgClosure *)mvar,info);
	    goto retry;
	}
	// we have the MVar, let's check whether the thread
	// is still blocked on the same MVar.
	if (target->why_blocked != BlockedOnMVar
	    || (StgMVar *)target->block_info.closure != mvar) {
	    unlockClosure((StgClosure *)mvar, info);
	    goto retry;
	}

	if ((target->flags & TSO_BLOCKEX) &&
	    ((target->flags & TSO_INTERRUPTIBLE) == 0)) {
            Capability *target_cap = target->cap;
            if (target->cap != cap) {
                throwToSendMsg(cap,target_cap,msg);
            } else {
                blockedThrowTo(cap,target,msg);
            }
	    unlockClosure((StgClosure *)mvar, info);
	    return THROWTO_BLOCKED;
	} else {
	    removeThreadFromMVarQueue(cap, mvar, target);
	    raiseAsync(cap, target, msg->exception, rtsFalse, NULL);
	    unblockOne(cap, target);
	    unlockClosure((StgClosure *)mvar, info);
	    return THROWTO_SUCCESS;
	}
    }

    case BlockedOnBlackHole:
    {
	ACQUIRE_LOCK(&sched_mutex);
	// double checking the status after the memory barrier:
	if (target->why_blocked != BlockedOnBlackHole) {
	    RELEASE_LOCK(&sched_mutex);
	    goto retry;
	}

	if (target->flags & TSO_BLOCKEX) {
            Capability *target_cap = target->cap;
            if (target->cap != cap) {
                throwToSendMsg(cap,target_cap,msg);
            } else {
                blockedThrowTo(cap,target,msg);
            }
	    RELEASE_LOCK(&sched_mutex);
	    return THROWTO_BLOCKED; // caller releases lock
	} else {
	    removeThreadFromQueue(cap, &blackhole_queue, target);
	    raiseAsync(cap, target, msg->exception, rtsFalse, NULL);
	    unblockOne(cap, target);
	    RELEASE_LOCK(&sched_mutex);
	    return THROWTO_SUCCESS;
	}
    }

    case BlockedOnSTM:
	lockTSO(target);
	// Unblocking BlockedOnSTM threads requires the TSO to be
	// locked; see STM.c:unpark_tso().
	if (target->why_blocked != BlockedOnSTM) {
	    unlockTSO(target);
	    goto retry;
	}
	if ((target->flags & TSO_BLOCKEX) &&
	    ((target->flags & TSO_INTERRUPTIBLE) == 0)) {
            Capability *target_cap = target->cap;
            if (target->cap != cap) {
                throwToSendMsg(cap,target_cap,msg);
            } else {
                blockedThrowTo(cap,target,msg);
            }
	    unlockTSO(target);
	    return THROWTO_BLOCKED;
	} else {
	    raiseAsync(cap, target, msg->exception, rtsFalse, NULL);
	    unblockOne(cap, target);
	    unlockTSO(target);
	    return THROWTO_SUCCESS;
	}

    case BlockedOnCCall:
    case BlockedOnCCall_NoUnblockExc:
    {
        Capability *target_cap;

        target_cap = target->cap;
        if (target_cap != cap) {
            throwToSendMsg(cap, target_cap, msg);
            return THROWTO_BLOCKED;
        }

	blockedThrowTo(cap,target,msg);
	return THROWTO_BLOCKED;
    }

#ifndef THREADEDED_RTS
    case BlockedOnRead:
    case BlockedOnWrite:
    case BlockedOnDelay:
#if defined(mingw32_HOST_OS)
    case BlockedOnDoProc:
#endif
	if ((target->flags & TSO_BLOCKEX) &&
	    ((target->flags & TSO_INTERRUPTIBLE) == 0)) {
	    blockedThrowTo(cap,target,msg);
	    return THROWTO_BLOCKED;
	} else {
	    removeFromQueues(cap,target);
	    raiseAsync(cap, target, msg->exception, rtsFalse, NULL);
	    return THROWTO_SUCCESS;
	}
#endif

    default:
	barf("throwTo: unrecognised why_blocked value");
    }
    barf("throwTo");
}

static void
throwToSendMsg (Capability *cap STG_UNUSED,
                Capability *target_cap USED_IF_THREADS, 
                MessageThrowTo *msg USED_IF_THREADS)
            
{
#ifdef THREADED_RTS
    debugTrace(DEBUG_sched, "throwTo: sending a throwto message to cap %lu", (unsigned long)target_cap->no);

    sendMessage(target_cap, (Message*)msg);
#endif
}

// Block a throwTo message on the target TSO's blocked_exceptions
// queue.  The current Capability must own the target TSO in order to
// modify the blocked_exceptions queue.
static void
blockedThrowTo (Capability *cap, StgTSO *target, MessageThrowTo *msg)
{
    debugTraceCap(DEBUG_sched, cap, "throwTo: blocking on thread %lu",
                  (unsigned long)target->id);

    ASSERT(target->cap == cap);

    msg->link = (Message*)target->blocked_exceptions;
    target->blocked_exceptions = msg;
    dirty_TSO(cap,target); // we modified the blocked_exceptions queue
}

/* -----------------------------------------------------------------------------
   Waking up threads blocked in throwTo

   There are two ways to do this: maybePerformBlockedException() will
   perform the throwTo() for the thread at the head of the queue
   immediately, and leave the other threads on the queue.
   maybePerformBlockedException() also checks the TSO_BLOCKEX flag
   before raising an exception.

   awakenBlockedExceptionQueue() will wake up all the threads in the
   queue, but not perform any throwTo() immediately.  This might be
   more appropriate when the target thread is the one actually running
   (see Exception.cmm).

   Returns: non-zero if an exception was raised, zero otherwise.
   -------------------------------------------------------------------------- */

int
maybePerformBlockedException (Capability *cap, StgTSO *tso)
{
    MessageThrowTo *msg;
    const StgInfoTable *i;
    
    if (tso->what_next == ThreadComplete || tso->what_next == ThreadFinished) {
        if (tso->blocked_exceptions != END_BLOCKED_EXCEPTIONS_QUEUE) {
            awakenBlockedExceptionQueue(cap,tso);
            return 1;
        } else {
            return 0;
        }
    }

    if (tso->blocked_exceptions != END_BLOCKED_EXCEPTIONS_QUEUE && 
        (tso->flags & TSO_BLOCKEX) != 0) {
        debugTrace(DEBUG_sched, "throwTo: thread %lu has blocked exceptions but is inside block", (unsigned long)tso->id);
    }

    if (tso->blocked_exceptions != END_BLOCKED_EXCEPTIONS_QUEUE
	&& ((tso->flags & TSO_BLOCKEX) == 0
	    || ((tso->flags & TSO_INTERRUPTIBLE) && interruptible(tso)))) {

	// We unblock just the first thread on the queue, and perform
	// its throw immediately.
    loop:
        msg = tso->blocked_exceptions;
        if (msg == END_BLOCKED_EXCEPTIONS_QUEUE) return 0;
        i = lockClosure((StgClosure*)msg);
        tso->blocked_exceptions = (MessageThrowTo*)msg->link;
        if (i == &stg_IND_info) {
            unlockClosure((StgClosure*)msg,i);
            goto loop;
        }

        performBlockedException(cap, msg);
        unblockOne_(cap, msg->source, rtsFalse/*no migrate*/);
        unlockClosure((StgClosure*)msg,&stg_IND_info);
        return 1;
    }
    return 0;
}

// awakenBlockedExceptionQueue(): Just wake up the whole queue of
// blocked exceptions and let them try again.

void
awakenBlockedExceptionQueue (Capability *cap, StgTSO *tso)
{
    MessageThrowTo *msg;
    const StgInfoTable *i;

    for (msg = tso->blocked_exceptions; msg != END_BLOCKED_EXCEPTIONS_QUEUE;
         msg = (MessageThrowTo*)msg->link) {
        i = lockClosure((StgClosure *)msg);
        if (i != &stg_IND_info) {
            unblockOne_(cap, msg->source, rtsFalse/*no migrate*/);
        }
        unlockClosure((StgClosure *)msg,i);
    }
    tso->blocked_exceptions = END_BLOCKED_EXCEPTIONS_QUEUE;
}    

static void
performBlockedException (Capability *cap, MessageThrowTo *msg)
{
    StgTSO *source;

    source = msg->source;

    ASSERT(source->why_blocked == BlockedOnMsgThrowTo);
    ASSERT(source->block_info.closure == (StgClosure *)msg);
    ASSERT(source->sp[0] == (StgWord)&stg_block_throwto_info);
    ASSERT(((StgTSO *)source->sp[1])->id == msg->target->id);
    // check ids not pointers, because the thread might be relocated

    throwToSingleThreaded(cap, msg->target, msg->exception);
    source->sp += 3;
}

/* -----------------------------------------------------------------------------
   Remove a thread from blocking queues.

   This is for use when we raise an exception in another thread, which
   may be blocked.

   Precondition: we have exclusive access to the TSO, via the same set
   of conditions as throwToSingleThreaded() (c.f.).
   -------------------------------------------------------------------------- */

static void
removeFromQueues(Capability *cap, StgTSO *tso)
{
  switch (tso->why_blocked) {

  case NotBlocked:
      return;

  case BlockedOnSTM:
    // Be careful: nothing to do here!  We tell the scheduler that the
    // thread is runnable and we leave it to the stack-walking code to
    // abort the transaction while unwinding the stack.  We should
    // perhaps have a debugging test to make sure that this really
    // happens and that the 'zombie' transaction does not get
    // committed.
    goto done;

  case BlockedOnMVar:
      removeThreadFromMVarQueue(cap, (StgMVar *)tso->block_info.closure, tso);
      goto done;

  case BlockedOnBlackHole:
      removeThreadFromQueue(cap, &blackhole_queue, tso);
      goto done;

  case BlockedOnMsgWakeup:
  {
      // kill the message, atomically:
      tso->block_info.wakeup->header.info = &stg_IND_info;
      break;
  }

  case BlockedOnMsgThrowTo:
  {
      MessageThrowTo *m = tso->block_info.throwto;
      // The message is locked by us, unless we got here via
      // deleteAllThreads(), in which case we own all the
      // capabilities.
      // ASSERT(m->header.info == &stg_WHITEHOLE_info);

      // unlock and revoke it at the same time
      unlockClosure((StgClosure*)m,&stg_IND_info);
      break;
  }

#if !defined(THREADED_RTS)
  case BlockedOnRead:
  case BlockedOnWrite:
#if defined(mingw32_HOST_OS)
  case BlockedOnDoProc:
#endif
      removeThreadFromDeQueue(cap, &blocked_queue_hd, &blocked_queue_tl, tso);
#if defined(mingw32_HOST_OS)
      /* (Cooperatively) signal that the worker thread should abort
       * the request.
       */
      abandonWorkRequest(tso->block_info.async_result->reqID);
#endif
      goto done;

  case BlockedOnDelay:
        removeThreadFromQueue(cap, &sleeping_queue, tso);
	goto done;
#endif

  default:
      barf("removeFromQueues: %d", tso->why_blocked);
  }

 done:
  unblockOne(cap, tso);
}

/* -----------------------------------------------------------------------------
 * raiseAsync()
 *
 * The following function implements the magic for raising an
 * asynchronous exception in an existing thread.
 *
 * We first remove the thread from any queue on which it might be
 * blocked.  The possible blockages are MVARs and BLACKHOLE_BQs.
 *
 * We strip the stack down to the innermost CATCH_FRAME, building
 * thunks in the heap for all the active computations, so they can 
 * be restarted if necessary.  When we reach a CATCH_FRAME, we build
 * an application of the handler to the exception, and push it on
 * the top of the stack.
 * 
 * How exactly do we save all the active computations?  We create an
 * AP_STACK for every UpdateFrame on the stack.  Entering one of these
 * AP_STACKs pushes everything from the corresponding update frame
 * upwards onto the stack.  (Actually, it pushes everything up to the
 * next update frame plus a pointer to the next AP_STACK object.
 * Entering the next AP_STACK object pushes more onto the stack until we
 * reach the last AP_STACK object - at which point the stack should look
 * exactly as it did when we killed the TSO and we can continue
 * execution by entering the closure on top of the stack.
 *
 * We can also kill a thread entirely - this happens if either (a) the 
 * exception passed to raiseAsync is NULL, or (b) there's no
 * CATCH_FRAME on the stack.  In either case, we strip the entire
 * stack and replace the thread with a zombie.
 *
 * ToDo: in THREADED_RTS mode, this function is only safe if either
 * (a) we hold all the Capabilities (eg. in GC, or if there is only
 * one Capability), or (b) we own the Capability that the TSO is
 * currently blocked on or on the run queue of.
 *
 * -------------------------------------------------------------------------- */

static void
raiseAsync(Capability *cap, StgTSO *tso, StgClosure *exception, 
	   rtsBool stop_at_atomically, StgUpdateFrame *stop_here)
{
    StgRetInfoTable *info;
    StgPtr sp, frame;
    StgClosure *updatee;
    nat i;

    debugTrace(DEBUG_sched,
	       "raising exception in thread %ld.", (long)tso->id);
    
#if defined(PROFILING)
    /* 
     * Debugging tool: on raising an  exception, show where we are.
     * See also Exception.cmm:stg_raisezh.
     * This wasn't done for asynchronous exceptions originally; see #1450 
     */
    if (RtsFlags.ProfFlags.showCCSOnException)
    {
        fprintCCS_stderr(tso->prof.CCCS);
    }
#endif

    while (tso->what_next == ThreadRelocated) {
        tso = tso->_link;
    }

    // mark it dirty; we're about to change its stack.
    dirty_TSO(cap, tso);

    sp = tso->sp;
    
    // ASSUMES: the thread is not already complete or dead.  Upper
    // layers should deal with that.
    ASSERT(tso->what_next != ThreadComplete && tso->what_next != ThreadKilled);

    if (stop_here != NULL) {
        updatee = stop_here->updatee;
    } else {
        updatee = NULL;
    }

    // The stack freezing code assumes there's a closure pointer on
    // the top of the stack, so we have to arrange that this is the case...
    //
    if (sp[0] == (W_)&stg_enter_info) {
	sp++;
    } else {
	sp--;
	sp[0] = (W_)&stg_dummy_ret_closure;
    }

    frame = sp + 1;
    while (stop_here == NULL || frame < (StgPtr)stop_here) {

	// 1. Let the top of the stack be the "current closure"
	//
	// 2. Walk up the stack until we find either an UPDATE_FRAME or a
	// CATCH_FRAME.
	//
	// 3. If it's an UPDATE_FRAME, then make an AP_STACK containing the
	// current closure applied to the chunk of stack up to (but not
	// including) the update frame.  This closure becomes the "current
	// closure".  Go back to step 2.
	//
	// 4. If it's a CATCH_FRAME, then leave the exception handler on
	// top of the stack applied to the exception.
	// 
	// 5. If it's a STOP_FRAME, then kill the thread.
        // 
        // NB: if we pass an ATOMICALLY_FRAME then abort the associated 
        // transaction
       
	info = get_ret_itbl((StgClosure *)frame);

	switch (info->i.type) {

	case UPDATE_FRAME:
	{
	    StgAP_STACK * ap;
	    nat words;
	    
	    // First build an AP_STACK consisting of the stack chunk above the
	    // current update frame, with the top word on the stack as the
	    // fun field.
	    //
	    words = frame - sp - 1;
	    ap = (StgAP_STACK *)allocate(cap,AP_STACK_sizeW(words));
	    
	    ap->size = words;
	    ap->fun  = (StgClosure *)sp[0];
	    sp++;
	    for(i=0; i < (nat)words; ++i) {
		ap->payload[i] = (StgClosure *)*sp++;
	    }
	    
	    SET_HDR(ap,&stg_AP_STACK_info,
		    ((StgClosure *)frame)->header.prof.ccs /* ToDo */); 
	    TICK_ALLOC_UP_THK(words+1,0);
	    
	    //IF_DEBUG(scheduler,
	    //	     debugBelch("sched: Updating ");
	    //	     printPtr((P_)((StgUpdateFrame *)frame)->updatee); 
	    //	     debugBelch(" with ");
	    //	     printObj((StgClosure *)ap);
	    //	);

            if (((StgUpdateFrame *)frame)->updatee == updatee) {
                // If this update frame points to the same closure as
                // the update frame further down the stack
                // (stop_here), then don't perform the update.  We
                // want to keep the blackhole in this case, so we can
                // detect and report the loop (#2783).
                ap = (StgAP_STACK*)updatee;
            } else {
                // Perform the update
                // TODO: this may waste some work, if the thunk has
                // already been updated by another thread.
                UPD_IND(cap, ((StgUpdateFrame *)frame)->updatee, (StgClosure *)ap);
            }

	    sp += sizeofW(StgUpdateFrame) - 1;
	    sp[0] = (W_)ap; // push onto stack
	    frame = sp + 1;
	    continue; //no need to bump frame
	}

	case STOP_FRAME:
	{
	    // We've stripped the entire stack, the thread is now dead.
	    tso->what_next = ThreadKilled;
	    tso->sp = frame + sizeofW(StgStopFrame);
	    return;
	}

	case CATCH_FRAME:
	    // If we find a CATCH_FRAME, and we've got an exception to raise,
	    // then build the THUNK raise(exception), and leave it on
	    // top of the CATCH_FRAME ready to enter.
	    //
	{
#ifdef PROFILING
	    StgCatchFrame *cf = (StgCatchFrame *)frame;
#endif
	    StgThunk *raise;
	    
	    if (exception == NULL) break;

	    // we've got an exception to raise, so let's pass it to the
	    // handler in this frame.
	    //
	    raise = (StgThunk *)allocate(cap,sizeofW(StgThunk)+1);
	    TICK_ALLOC_SE_THK(1,0);
	    SET_HDR(raise,&stg_raise_info,cf->header.prof.ccs);
	    raise->payload[0] = exception;
	    
	    // throw away the stack from Sp up to the CATCH_FRAME.
	    //
	    sp = frame - 1;
	    
	    /* Ensure that async excpetions are blocked now, so we don't get
	     * a surprise exception before we get around to executing the
	     * handler.
	     */
	    tso->flags |= TSO_BLOCKEX | TSO_INTERRUPTIBLE;

	    /* Put the newly-built THUNK on top of the stack, ready to execute
	     * when the thread restarts.
	     */
	    sp[0] = (W_)raise;
	    sp[-1] = (W_)&stg_enter_info;
	    tso->sp = sp-1;
	    tso->what_next = ThreadRunGHC;
	    IF_DEBUG(sanity, checkTSO(tso));
	    return;
	}
	    
	case ATOMICALLY_FRAME:
	    if (stop_at_atomically) {
		ASSERT(tso->trec->enclosing_trec == NO_TREC);
		stmCondemnTransaction(cap, tso -> trec);
		tso->sp = frame - 2;
                // The ATOMICALLY_FRAME expects to be returned a
                // result from the transaction, which it stores in the
                // stack frame.  Hence we arrange to return a dummy
                // result, so that the GC doesn't get upset (#3578).
                // Perhaps a better way would be to have a different
                // ATOMICALLY_FRAME instance for condemned
                // transactions, but I don't fully understand the
                // interaction with STM invariants.
                tso->sp[1] = (W_)&stg_NO_TREC_closure;
                tso->sp[0] = (W_)&stg_gc_unpt_r1_info;
		tso->what_next = ThreadRunGHC;
		return;
	    }
	    // Not stop_at_atomically... fall through and abort the
	    // transaction.
	    
	case CATCH_STM_FRAME:
	case CATCH_RETRY_FRAME:
	    // IF we find an ATOMICALLY_FRAME then we abort the
	    // current transaction and propagate the exception.  In
	    // this case (unlike ordinary exceptions) we do not care
	    // whether the transaction is valid or not because its
	    // possible validity cannot have caused the exception
	    // and will not be visible after the abort.

		{
            StgTRecHeader *trec = tso -> trec;
            StgTRecHeader *outer = trec -> enclosing_trec;
	    debugTrace(DEBUG_stm, 
		       "found atomically block delivering async exception");
            stmAbortTransaction(cap, trec);
	    stmFreeAbortedTRec(cap, trec);
            tso -> trec = outer;
	    break;
	    };
	    
	default:
	    break;
	}

	// move on to the next stack frame
	frame += stack_frame_sizeW((StgClosure *)frame);
    }

    // if we got here, then we stopped at stop_here
    ASSERT(stop_here != NULL);
}


