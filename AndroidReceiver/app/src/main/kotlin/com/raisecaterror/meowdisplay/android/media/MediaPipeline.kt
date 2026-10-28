package com.raisecaterror.meowdisplay.android.media

import com.raisecaterror.meowdisplay.android.session.MediaController
import com.raisecaterror.meowdisplay.core.session.SessionEvent
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Admitted media from the session to the decoders. The session already dropped anything unadmitted. */
class MediaPipeline(media: MediaController, avSyncOffsetMs: () -> Int = { 0 }) {
    private val size = MutableStateFlow<Pair<Int, Int>?>(null)

    /** The decoded picture's size, for letterboxing; null until a frame decodes. */
    val videoSize: StateFlow<Pair<Int, Int>?> = size.asStateFlow()

    val video = VideoDecoder(requestKeyframe = { media.session.requestKeyframe() }, onVideoSize = { w, h -> size.value = w to h })
    private val audio = AudioPlayer(avSyncOffsetMs)

    init {
        media.mediaEvents = ::onEvent
    }

    private fun onEvent(event: SessionEvent) {
        when (event) {
            is SessionEvent.Video -> video.submit(event.sample)
            is SessionEvent.Audio -> audio.submit(event.frame)
            is SessionEvent.CodecChanged -> video.reset()
            is SessionEvent.VideoState -> if (!event.enabled) clearVideo()
            is SessionEvent.AudioState -> if (!event.enabled) audio.stop()
            is SessionEvent.DisplayPaused -> if (event.paused) audio.stop()
            is SessionEvent.Connected, is SessionEvent.Disconnected, SessionEvent.AdmissionWithdrawn -> {
                clearVideo()
                audio.stop()
            }
            else -> Unit
        }
    }

    private fun clearVideo() {
        video.reset()
        size.value = null
    }
}
