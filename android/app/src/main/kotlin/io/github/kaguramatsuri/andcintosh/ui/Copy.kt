package io.github.kaguramatsuri.andcintosh.ui

import io.github.kaguramatsuri.andcintosh.R
import io.github.kaguramatsuri.andcintosh.core.Failure
import io.github.kaguramatsuri.andcintosh.core.ProtocolException

fun failureText(error: Throwable): Int = failureText((error as? ProtocolException)?.code)
fun failureText(code: Failure?): Int = when (code) {
    Failure.unsupportedVersion -> R.string.error_version
    Failure.invalidKey -> R.string.error_key
    Failure.authenticationFailed -> R.string.error_auth
    Failure.originalUnavailable -> R.string.error_original
    Failure.sourceUnavailable -> R.string.error_source
    Failure.insufficientSpace -> R.string.error_space
    Failure.digestMismatch -> R.string.error_digest
    Failure.permissionDenied -> R.string.error_permission
    Failure.peerUnavailable, Failure.timeout -> R.string.error_peer
    Failure.unsupported -> R.string.error_unsupported
    Failure.invalidName -> R.string.error_name
    Failure.cancelled -> R.string.error_cancelled
    Failure.invalidHandshake, Failure.invalidFrame, Failure.replay, Failure.oversizedRecord,
    Failure.invalidManifest, Failure.invalidOffset -> R.string.error_protocol
    null -> R.string.error_generic
}
