package app.marten.client.bg

import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Test

class ServiceNotificationBytesFormatTest {
    @Test
    fun `formatter uses decimal SI units from bytes through exabytes`() {
        val cases = listOf(
            0L to "0 B",
            9L to "9 B",
            10L to "10 B",
            999L to "999 B",
            1_000L to "1.0 kB",
            1_000_000L to "1.0 MB",
            1_000_000_000L to "1.0 GB",
            1_000_000_000_000L to "1.0 TB",
            1_000_000_000_000_000L to "1.0 PB",
            1_000_000_000_000_000_000L to "1.0 EB",
        )
        cases.forEach { (bytes, expected) -> assertEquals("$bytes bytes", expected, formatNotificationBytes(bytes)) }
    }

    @Test
    fun `formatter rounds half up and switches precision at rounded ten`() {
        assertEquals("9.5 kB", formatNotificationBytes(9_499L))
        assertEquals("1.0 kB", formatNotificationBytes(1_049L))
        assertEquals("1.1 kB", formatNotificationBytes(1_050L))
        assertEquals("10 kB", formatNotificationBytes(9_999L))
        assertEquals("1000 kB", formatNotificationBytes(999_999L))
        assertEquals("1.0 MB", formatNotificationBytes(1_000_000L))
    }

    @Test
    fun `formatter clamps negative values and remains safe at Long maximum`() {
        assertEquals("0 B", formatNotificationBytes(-1L))
        assertEquals("0 B", formatNotificationBytes(Long.MIN_VALUE))
        assertEquals("9.2 EB", formatNotificationBytes(Long.MAX_VALUE))
    }

    @Test
    fun `formatter output is independent of the process locale`() {
        val original = Locale.getDefault()
        try {
            Locale.setDefault(Locale.GERMANY)
            assertEquals("1.5 kB", formatNotificationBytes(1_500L))
        } finally {
            Locale.setDefault(original)
        }
    }
}
