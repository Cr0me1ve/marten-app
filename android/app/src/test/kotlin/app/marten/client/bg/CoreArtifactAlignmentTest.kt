package app.marten.client.bg

import java.io.BufferedInputStream
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.zip.ZipFile
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CoreArtifactAlignmentTest {
    @Test
    fun `arm64 native core in the consumed AAR has 16 KiB aligned LOAD segments`() {
        val aar = listOf(
            File("libs/marten-core.aar"),
            File("app/libs/marten-core.aar"),
            File("android/app/libs/marten-core.aar"),
        ).firstOrNull { it.isFile }
        assertTrue("the Android app must consume its local marten-core AAR", aar?.isFile == true)

        ZipFile(aar!!).use { zip ->
            val entry = zip.getEntry("jni/arm64-v8a/libmarten-core.so")
            assertTrue("the AAR must contain the arm64 native core", entry != null)
            zip.getInputStream(entry).use { raw ->
                val input = BufferedInputStream(raw)
                val headerBytes = readExactly(input, 64)
                assertEquals("ELF magic", listOf(0x7f, 0x45, 0x4c, 0x46), headerBytes.take(4).map { it.toInt() and 0xff })
                assertEquals("native core is ELF64", 2, headerBytes[4].toInt())
                assertEquals("native core uses little-endian ELF", 1, headerBytes[5].toInt())

                val header = ByteBuffer.wrap(headerBytes).order(ByteOrder.LITTLE_ENDIAN)
                val programOffset = header.getLong(32)
                val programEntrySize = header.getShort(54).toInt() and 0xffff
                val programCount = header.getShort(56).toInt() and 0xffff
                assertTrue("ELF program table uses ELF64 entries", programEntrySize >= 56)
                assertTrue("ELF has loadable program headers", programCount > 0)
                val tableEnd = programOffset + programEntrySize.toLong() * programCount
                assertTrue("ELF program table is a bounded header structure", programOffset >= 64 && tableEnd <= 1_048_576)

                skipExactly(input, programOffset - 64)
                val tableBytes = readExactly(input, (programEntrySize * programCount))
                val table = ByteBuffer.wrap(tableBytes).order(ByteOrder.LITTLE_ENDIAN)
                var loadCount = 0
                repeat(programCount) { index ->
                    val offset = index * programEntrySize
                    val type = table.getInt(offset)
                    if (type == PT_LOAD) {
                        loadCount++
                        val fileOffset = table.getLong(offset + 8)
                        val virtualAddress = table.getLong(offset + 16)
                        val alignment = table.getLong(offset + 48)
                        assertTrue("PT_LOAD segment $index must support 16 KiB device pages (p_align=$alignment)", alignment >= ANDROID_PAGE_SIZE)
                        assertEquals(
                            "PT_LOAD segment $index p_offset and p_vaddr must be congruent at p_align=$alignment",
                            fileOffset % alignment,
                            virtualAddress % alignment,
                        )
                    }
                }
                assertFalse("the core shared object must contain LOAD segments", loadCount == 0)
            }
        }
    }

    private fun readExactly(input: BufferedInputStream, size: Int): ByteArray {
        val bytes = ByteArray(size)
        var offset = 0
        while (offset < size) {
            val count = input.read(bytes, offset, size - offset)
            check(count > 0) { "truncated ELF header" }
            offset += count
        }
        return bytes
    }

    private fun skipExactly(input: BufferedInputStream, size: Long) {
        var remaining = size
        while (remaining > 0) {
            val skipped = input.skip(remaining)
            if (skipped > 0) {
                remaining -= skipped
            } else {
                check(input.read() >= 0) { "truncated ELF program table" }
                remaining--
            }
        }
    }

    private companion object {
        const val PT_LOAD = 1
        const val ANDROID_PAGE_SIZE = 16_384L
    }
}
