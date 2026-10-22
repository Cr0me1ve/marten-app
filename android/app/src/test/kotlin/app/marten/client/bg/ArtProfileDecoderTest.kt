package app.marten.client.bg

import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.charset.StandardCharsets
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ArtProfileDecoderTest {
    @Test
    fun `decodes v3 slow sampling records and reports function CPU without thread identity`() {
        val summary = decodeArtProfile(v3Trace())

        assertEquals("ready", summary.status)
        assertEquals(4, summary.records)
        assertEquals(3_000L, summary.totalCpuUs)
        assertTrue(summary.text.contains("flat_us=2000 inclusive_us=3000 symbol=com:example:Foo::work"))
        assertTrue(summary.text.contains("flat_us=1000 inclusive_us=1000 symbol=com:example:Bar::spin"))
        assertFalse(summary.text.contains("Very Private Thread Name"))
        assertFalse(summary.text.contains("thread_id"))
    }

    @Test
    fun `rejects malformed or unsupported ART trace headers`() {
        val error = runCatching { decodeArtProfile("not an ART trace".toByteArray()) }.exceptionOrNull()
        assertNotNull("malformed trace should be rejected", error)
    }

    @Test
    fun `decodes JVMTI kernel CPU functions and preserves explicit coverage limits`() {
        val profile = """
            ART_PROFILE outcome=ready clock=thread_cpu_kernel records=17 total_observed_us=1200000 format=jvmti_kernel_cpu scope=sampled_java_and_native_entry_frames
            ART_COVERAGE polls=31 unmapped_thread_observations=2 ended_thread_observations=3 cpu_read_failures=1 unresolved_cpu_us=80000 dropped_entries=4 cpu_tick_us=10000 attribution=interval_cpu_weighted_stack native_unattached=unavailable
            FUNCTION flat_us=900000 inclusive_us=1100000 symbol=app/marten/client/bg/HotWorker::artProfilerCpuWork
            STACK value_us=80000 frames=app/marten/client/bg/HotWorker::artProfilerCpuWork <- app/marten/client/bg/HotWorker::run
        """.trimIndent() + "\n"

        val summary = decodeJvmtiProfile(profile.toByteArray())

        assertEquals("ready", summary.status)
        assertEquals(17, summary.records)
        assertEquals(1_200_000L, summary.totalCpuUs)
        assertTrue(summary.text.contains("format=jvmti_kernel_cpu"))
        assertTrue(summary.text.contains("unmapped_thread_observations=2"))
        assertTrue(summary.text.contains("ended_thread_observations=3"))
        assertTrue(summary.text.contains("cpu_read_failures=1"))
        assertTrue(summary.text.contains("unresolved_cpu_us=80000"))
        assertTrue(summary.text.contains("native_unattached=unavailable"))
        assertTrue(summary.text.contains("symbol=app/marten/client/bg/HotWorker::artProfilerCpuWork"))
        assertTrue(summary.historyText.contains("STACK value_us=80000"))
    }

    @Test
    fun `rejects malformed JVMTI rows and oversized private profile content`() {
        val badRow = """
            ART_PROFILE outcome=ready clock=thread_cpu_kernel records=1 total_observed_us=10 format=jvmti_kernel_cpu scope=sampled_java_and_native_entry_frames
            FUNCTION flat_us=10 inclusive_us=10 symbol=/private/path/HotWorker
        """.trimIndent()
        assertNotNull("arbitrary path-bearing symbols must fail closed", runCatching { decodeJvmtiProfile(badRow.toByteArray()) }.exceptionOrNull())

        val oversized = ByteArray(2 * 1024 * 1024 + 1) { 'x'.code.toByte() }
        assertNotNull("JVMTI spool payloads must stay bounded", runCatching { decodeJvmtiProfile(oversized) }.exceptionOrNull())
    }

    private fun v3Trace(): ByteArray {
        val textHeader = """*version
3
clock=thread-cpu
*threads
7\tVery Private Thread Name
*methods
0x00000100\tLcom.example.Foo;\twork\t()V
0x00000104\tLcom.example.Bar;\tspin\t()V
*end
""".replace("\\t", "\t")
        val headerBytes = textHeader.toByteArray(StandardCharsets.UTF_8)
        val recordSize = 18
        val headerSize = 18
        val out = ByteArrayOutputStream()
        out.write(headerBytes)
        val binaryHeader = ByteBuffer.allocate(headerSize).order(ByteOrder.LITTLE_ENDIAN)
        binaryHeader.put("SLOW".toByteArray(StandardCharsets.US_ASCII))
        binaryHeader.putShort(3.toShort())
        binaryHeader.putShort(headerSize.toShort())
        binaryHeader.putInt(0) // start time
        binaryHeader.putInt(0) // record count
        binaryHeader.putShort(recordSize.toShort())
        out.write(binaryHeader.array())
        listOf(
            Record(method = 0x100, time = 100),
            Record(method = 0x104, time = 1_100),
            Record(method = 0x104, time = 2_100, action = 1),
            Record(method = 0x100, time = 3_100, action = 1),
        ).forEach { record ->
            val bytes = ByteBuffer.allocate(recordSize).order(ByteOrder.LITTLE_ENDIAN)
            bytes.putShort(7.toShort())
            bytes.putInt(record.method or record.action)
            bytes.putInt(record.time)
            while (bytes.hasRemaining()) bytes.put(0)
            out.write(bytes.array())
        }
        return out.toByteArray()
    }

    private data class Record(val method: Int, val time: Int, val action: Int = 0)
}
