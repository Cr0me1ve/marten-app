package app.marten.client.bg

import android.os.Process
import java.io.File

internal data class EnergyPhaseSnapshot(val signature: String, val active: Boolean, val interrupted: Boolean = false)

internal fun energyOrdinaryWindow(previous: EnergyPhaseSnapshot?, current: EnergyPhaseSnapshot, quietBefore: Int): Boolean =
    previous != null && !previous.active && !current.active && previous.signature == current.signature && quietBefore >= 1

internal fun readEnergyPhases(directory: File): EnergyPhaseSnapshot {
    var active = false
    var interrupted = false
    val signature = listOf("core", "art", "dart", "decode").joinToString("|") { source ->
        val file = File(directory, "$source-phase.txt")
        val fields = runCatching {
            if (!file.isFile || file.length() > 512) return@runCatching emptyMap<String, String>()
            file.readText().trim().split(Regex("\\s+")).mapNotNull { token ->
                token.split('=', limit = 2).takeIf { it.size == 2 }?.let { it[0] to it[1] }
            }.toMap()
        }.getOrDefault(emptyMap())
        val phase = fields["phase"] ?: "idle"
        val sequence = fields["sequence"]?.takeIf { Regex("[0-9]+-[0-9]+").matches(it) } ?: "0-0"
        val pid = fields["pid"]?.toIntOrNull()
        val dead = pid != null && pid > 0 && !File("/proc/$pid").exists()
        if (phase != "idle") {
            if (dead) interrupted = true else active = true
        }
        "$source:$sequence:${if (dead) "interrupted" else phase}"
    }
    return EnergyPhaseSnapshot(signature, active, interrupted)
}

internal class EnergyProfilePhase(private val directory: File, private val source: String) {
    private val generation = System.currentTimeMillis()
    private var sequence = 0
    fun begin(phase: String = "decode") { sequence++; write(phase) }
    fun end() = write("idle")
    private fun write(phase: String) {
        directory.mkdirs()
        writeProfileAtomic(File(directory, "$source-phase.txt"), "phase=$phase sequence=$generation-$sequence pid=${Process.myPid()}\n")
    }
}
