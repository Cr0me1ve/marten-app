package app.marten.client.bg

import java.io.File
import java.io.IOException
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class EnergyDecodeJobTest {
    @Test
    fun `malformed closed job fails once and releases its exact slot`() {
        val directory = Files.createTempDirectory("marten-energy-job-").toFile()
        try {
            val marker = File(directory, "art-0.ready").apply { writeText("x".repeat(2049)) }
            val raw = File(directory, "art-0.jvmti").apply { writeText("private raw data") }
            var decodes = 0
            val losses = mutableListOf<String>()

            val result = runClosedEnergyJob(marker, listOf(raw), { losses += it }) { decodes++ }

            assertFalse(result)
            assertEquals(0, decodes)
            assertEquals(listOf("invalid_capture"), losses)
            assertFalse(marker.exists())
            assertFalse(raw.exists())
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun `transient decode IO retries within bound and successful retry cleans files without loss`() {
        val directory = Files.createTempDirectory("marten-energy-job-").toFile()
        try {
            val marker = File(directory, "core-0.job").apply { writeText("closed generation") }
            val raw = File(directory, "core-0-cpu.raw").apply { writeText("raw profile") }
            var decodes = 0
            val losses = mutableListOf<String>()

            val result = runClosedEnergyJob(marker, listOf(raw), { losses += it }) {
                decodes++
                if (decodes < 3) throw IOException("temporary read failure")
            }

            assertTrue(result)
            assertEquals(3, decodes)
            assertTrue(losses.isEmpty())
            assertFalse(marker.exists())
            assertFalse(raw.exists())
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun `permanent malformed decode does not retry and reports one loss`() {
        val directory = Files.createTempDirectory("marten-energy-job-").toFile()
        try {
            val marker = File(directory, "core-1.job").apply { writeText("closed generation") }
            val raw = File(directory, "core-1-cpu.raw").apply { writeText("bad profile") }
            var decodes = 0
            val losses = mutableListOf<String>()

            val result = runClosedEnergyJob(marker, listOf(raw), { losses += it }) {
                decodes++
                throw IllegalArgumentException("malformed profile")
            }

            assertFalse(result)
            assertEquals(1, decodes)
            assertEquals(listOf("invalid_capture"), losses)
            assertFalse(marker.exists())
            assertFalse(raw.exists())
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun `replacement marker keeps the successor slot and raw input intact`() {
        val directory = Files.createTempDirectory("marten-energy-job-").toFile()
        try {
            val marker = File(directory, "core-2.job").apply { writeText("old generation") }
            val raw = File(directory, "core-2-cpu.raw").apply { writeText("old raw") }
            val losses = mutableListOf<String>()

            val result = runClosedEnergyJob(marker, listOf(raw), { losses += it }) {
                marker.writeText("successor generation is longer")
                raw.writeText("successor raw")
            }

            assertTrue(result)
            assertTrue(losses.isEmpty())
            assertEquals("successor generation is longer", marker.readText())
            assertEquals("successor raw", raw.readText())
        } finally {
            directory.deleteRecursively()
        }
    }
}
