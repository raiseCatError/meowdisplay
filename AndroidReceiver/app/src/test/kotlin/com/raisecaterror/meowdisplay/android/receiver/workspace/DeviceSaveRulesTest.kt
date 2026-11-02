package com.raisecaterror.meowdisplay.android.receiver.workspace

import org.junit.Assert.assertEquals
import org.junit.Test

/** Save to device from Remote Finder (owner, 2026-10-31): photos and videos to the gallery, the rest to Downloads. */
class DeviceSaveRulesTest {
    @Test
    fun photosAndVideosGoToTheGalleryEverythingElseToDownloads() {
        assertEquals(SaveDestination.Pictures, DeviceSaveRules.destination("IMG_2192.PNG", topLevel = true))
        assertEquals(SaveDestination.Pictures, DeviceSaveRules.destination("photo.heic", topLevel = true))
        assertEquals(SaveDestination.Movies, DeviceSaveRules.destination("clip.MOV", topLevel = true))
        assertEquals(SaveDestination.Downloads, DeviceSaveRules.destination("invoice.pdf", topLevel = true))
        assertEquals(SaveDestination.Downloads, DeviceSaveRules.destination("README", topLevel = true))
        assertEquals("files inside a saved folder keep its layout", SaveDestination.Downloads, DeviceSaveRules.destination("a.jpg", topLevel = false))
    }

    @Test
    fun theMessageSaysWhereThingsWent() {
        assertEquals("Saved 2 to Photos (Pictures/Movies ▸ MeowDisplay), 1 to Download ▸ MeowDisplay.", DeviceSaveResult(2, 1, 0).message(0))
        assertEquals("Saved 1 to Download ▸ MeowDisplay. 2 couldn't be saved.", DeviceSaveResult(0, 1, 1).message(1))
        assertEquals("Nothing could be saved.", DeviceSaveResult(0, 0, 0).message(0))
    }
}
