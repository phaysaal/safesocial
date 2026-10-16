package com.spheres.spheres_app

import org.autoear.v2.api.SegmentWindow
import org.autoear.v2.api.Session
import org.autoear.v2.state.NoteKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The engine behind CallNotes, driven the way a call drives it: one session,
 * one finalised segment at a time with its window, the speaker "You".
 * Proves the jar in libs/ loads with its dictionary and grammar and that a
 * short scripted call yields notes and a summary.
 */
class CallNotesEngineTest {
    private fun window(i: Int) = SegmentWindow(i * 10_000L, i * 10_000L + 9_000)

    @Test
    fun aScriptedCallYieldsNotesAndASummary() {
        val s = Session(sessionId = "call-1")
        // The engine's own documented examples, spoken by one side of a call.
        val lines = listOf(
            "The deadline is Friday.",
            "We need to move the deadline to Tuesday.",
            "Sarah will send the report by Friday.",
            "We've decided to invite Alice to the demonstration.",
        )
        val admitted = lines.mapIndexed { i, t -> s.analyze(t, window(i), "You").admitted }.flatten()
        assertTrue("expected notes, got $admitted", admitted.size >= 3)
        assertTrue(admitted.any { it.kind == NoteKind.FACT })
        assertTrue(admitted.any { it.kind == NoteKind.PROPOSAL })
        assertTrue(admitted.any { it.kind == NoteKind.ACTION && it.owner != null })
        assertTrue(admitted.any { it.kind == NoteKind.DECISION })
        assertTrue(admitted.all { it.speakerSource == "You" })

        val md = s.markdown()
        assertTrue(md.isNotBlank())
        assertTrue(md.contains("Friday"))
        assertEquals(admitted.size, s.state.notes.size)
        s.close()
    }

    @Test
    fun smallTalkYieldsNothing() {
        val s = Session(sessionId = "call-2")
        val out = s.analyze("Hello, how are you doing today?", window(0), "You")
        assertTrue(out.admitted.isEmpty())
    }

    @Test
    fun onlyEnglishIsRead() {
        try {
            Session(sessionId = "call-3", language = "de")
            assertTrue("a non-English session must be refused", false)
        } catch (e: IllegalArgumentException) {
            // as documented
        }
    }
}
