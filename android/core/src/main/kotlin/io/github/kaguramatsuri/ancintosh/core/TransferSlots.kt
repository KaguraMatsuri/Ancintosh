package io.github.kaguramatsuri.ancintosh.core

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

internal class ChannelLifetime { @Volatile var closed = false }
/** Reserve before reading payloads; each slot accounts for at most 64 KiB. */
internal class TransferSlots(private var available: Int) {
    private class Waiter(val owner: ChannelLifetime) {
        val completion = CompletableDeferred<Unit>()
        var granted = false
    }
    private val waiters = ArrayDeque<Waiter>()
    suspend fun acquire(owner: ChannelLifetime) {
        currentCoroutineContext().ensureActive()
        val waiter = Waiter(owner)
        synchronized(this) {
            if (owner.closed) fail(Failure.peerUnavailable)
            if (available > 0) { available--; return }
            waiters.addLast(waiter)
        }
        try { waiter.completion.await() }
        catch (error: Exception) {
            synchronized(this) { waiters.remove(waiter); if (waiter.granted) release() }
            throw error
        }
    }
    @Synchronized fun release() {
        while (waiters.isNotEmpty()) {
            val waiter = waiters.removeFirst()
            if (waiter.owner.closed) waiter.completion.completeExceptionally(ProtocolException(Failure.peerUnavailable))
            else { waiter.granted = true; waiter.completion.complete(Unit); return }
        }
        available++
    }
    @Synchronized fun removeClosedWaiters() {
        val stopped = waiters.filter { it.owner.closed }; waiters.removeAll(stopped.toSet())
        stopped.forEach { it.completion.completeExceptionally(ProtocolException(Failure.peerUnavailable)) }
    }
    companion object { val shared = TransferSlots(128) }
}
