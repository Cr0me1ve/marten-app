package app.marten.client.bg

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CompactCpuProfileTest {
    @Test
    fun `decodes repeated compact samples into leaf first flat and inclusive symbols`() {
        val trace = trace(
            names = listOf(1L to "package:features/home.dart::buildHome", 2L to "HomePage.paint"),
            frames = listOf(11L to 1L, 12L to 2L),
            stacks = listOf(21L to listOf(11L, 12L)),
            samples = listOf(21L, 21L),
        )

        val summary = decodePerfettoCpuSamples(trace, periodUs = 20_000)

        assertEquals(2, summary.samples)
        assertEquals(0, summary.unknownSamples)
        assertTrue(summary.text.contains("period_us=20000 unresolved_leaf_samples=0 format=compact_perfetto"))
        assertTrue(summary.text.contains("FUNCTION flat_samples=2 inclusive_samples=2 symbol=HomePage::paint"))
        assertTrue(summary.text.contains("FUNCTION flat_samples=0 inclusive_samples=2 symbol=package:features/home::dart::buildHome"))
        assertTrue(summary.text.contains("frames=HomePage::paint <- package:features/home::dart::buildHome"))
    }

    @Test
    fun `counts unresolved leaves and removes paths addresses ids and dynamic names`() {
        val trace = trace(
            names = listOf(1L to "/data/app/private-install/lib.so+0x7f1234", 2L to "https://private.example.test/path?token=secret"),
            frames = listOf(11L to 1L, 12L to 2L),
            stacks = listOf(21L to listOf(11L), 22L to listOf(12L)),
            samples = listOf(21L, 22L),
        )

        val summary = decodePerfettoCpuSamples(trace, periodUs = 1_000)

        assertEquals(2, summary.samples)
        assertEquals(2, summary.unknownSamples)
        assertTrue(summary.text.contains("unresolved_leaf_samples=2"))
        for (privateValue in listOf("private-install", "0x7f1234", "private.example.test", "token=secret", "11", "21")) {
            assertFalse("summary retained $privateValue", summary.text.contains(privateValue))
        }
    }

    @Test
    fun `rejects malformed protobuf and oversized trace`() {
        assertTrue(runCatching { decodePerfettoCpuSamples(byteArrayOf(0x0a, 0x05, 0x01), 1) }.isFailure)
        assertTrue(runCatching { decodePerfettoCpuSamples(ByteArray(8 * 1024 * 1024 + 1), 1) }.isFailure)
    }

    private fun trace(
        names: List<Pair<Long, String>>,
        frames: List<Pair<Long, Long>>,
        stacks: List<Pair<Long, List<Long>>>,
        samples: List<Long>,
    ): ByteArray {
        val interned = buildList {
            names.forEach { (id, name) -> add(bytesField(5, varintField(1, id) + bytesField(2, name.toByteArray()))) }
            frames.forEach { (id, nameId) -> add(bytesField(6, varintField(1, id) + varintField(2, nameId))) }
            stacks.forEach { (id, frameIds) -> add(bytesField(7, varintField(1, id) + frameIds.fold(byteArrayOf()) { acc, frame -> acc + varintField(2, frame) })) }
        }.fold(byteArrayOf()) { acc, item -> acc + item }
        val packetBase = bytesField(12, interned)
        return samples.fold(byteArrayOf()) { acc, stackId ->
            val packet = packetBase + bytesField(66, varintField(4, stackId))
            acc + bytesField(1, packet)
        }
    }

    private fun bytesField(number: Int, value: ByteArray): ByteArray =
        varint(((number shl 3) or 2).toLong()) + varint(value.size.toLong()) + value

    private fun varintField(number: Int, value: Long): ByteArray =
        varint((number shl 3).toLong()) + varint(value)

    private fun varint(value: Long): ByteArray {
        var remaining = value
        val out = ArrayList<Byte>()
        while ((remaining and -128L) != 0L) {
            out.add(((remaining and 127L) or 128L).toByte())
            remaining = remaining ushr 7
        }
        out.add(remaining.toByte())
        return out.toByteArray()
    }
}
