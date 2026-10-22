package app.marten.client.crashreporting

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CrashlyticsNdkBuildConfigTest {
    private val buildScript by lazy {
        val file = File("build.gradle")
        check(file.isFile) { "missing Android app build script ${file.absolutePath}" }
        stripComments(file.readText())
    }

    @Test
    fun `Firebase Gradle plugins are applied only when public project configuration exists`() {
        assertTrue(buildScript.contains("def hasFirebaseConfig = file(\"google-services.json\").exists()"))
        assertTrue(buildScript.contains("if (hasFirebaseConfig)"))
        assertTrue(buildScript.contains("apply plugin: \"com.google.gms.google-services\""))
        assertTrue(buildScript.contains("apply plugin: \"com.google.firebase.crashlytics\""))
    }

    @Test
    fun `Crashlytics NDK SDK captures fatal signals from marten core when configured`() {
        assertTrue(
            "firebase-crashlytics-ndk is required to capture SIGABRT and SIGSEGV from libmarten-core.so",
            findCodeMatch(
                Regex(
                    """(?m)^\s*implementation\s*(?:\(\s*)?[\"']com\.google\.firebase:firebase-crashlytics-ndk(?:[^\"']*)[\"']\s*\)?\s*$""",
                ),
                buildScript,
            ) != null,
        )
    }

    @Test
    fun `release extracts exact arm64 marten core library into the configured symbols directory`() {
        val aarPath = fileAssignment("martenCoreAar")
        val symbolsPath = fileAssignment("martenCoreCrashlyticsSymbolsDir")
        val extraction = registeredTaskBlock("extractMartenCoreCrashlyticsSymbols")

        assertEquals("libs/marten-core.aar", aarPath)
        assertTrue(
            "symbols must be extracted into a dedicated build output, not pointed at app/libs",
            symbolsPath.contains("marten_core_crashlytics_symbols/release"),
        )
        assertFalse("the AAR directory is not an unstripped-library directory", symbolsPath == "libs")
        assertTrue(
            findCodeMatch(Regex("""(?m)^\s*inputs\.file\s*\(\s*martenCoreAar\s*\)\s*$"""), extraction) != null,
        )
        assertTrue(
            "the extraction task must unzip the actual marten-core AAR",
            findCodeMatch(
                Regex("""\bfrom\s*\(\s*zipTree\s*\(\s*martenCoreAar\s*\)\s*\)\s*\{"""),
                extraction,
            ) != null,
        )
        assertTrue(
            "only the packaged arm64 Marten native core should feed Crashlytics",
            findCodeMatch(
                Regex("""(?m)^\s*include\s+[\"']jni/arm64-v8a/libmarten-core\.so[\"']\s*$"""),
                extraction,
            ) != null,
        )
        assertTrue(
            findCodeMatch(
                Regex("""(?m)^\s*into\s*\(\s*martenCoreCrashlyticsSymbolsDir\s*\)\s*$"""),
                extraction,
            ) != null,
        )

        val android = namedBlock(buildScript, "android")
        val buildTypes = namedBlock(android, "buildTypes")
        val release = namedBlock(buildTypes, "release")
        val crashlytics = namedBlock(release, "firebaseCrashlytics")

        assertTrue(
            "release must enable the Crashlytics native-symbol upload task",
            findCodeMatch(
                Regex("""(?m)^\s*nativeSymbolUploadEnabled\s*(?:=\s*)?true\s*$"""),
                crashlytics,
            ) != null,
        )
        val configuredSymbolsPath = requireNotNull(
            findCodeMatch(
                Regex(
                    """(?m)^\s*unstrippedNativeLibsDir\s*(?:=\s*)?(?:(?:rootProject|project)\.)?file\s*\(\s*[\"']([^\"']+)[\"']\s*\)\s*$""",
                ),
                crashlytics,
            )?.groupValues?.get(1),
        ) {
            "release must explicitly point Crashlytics at extracted libmarten-core.so symbols"
        }
        assertEquals(
            "Crashlytics and the extraction task must use the same symbols directory",
            symbolsPath,
            configuredSymbolsPath,
        )
    }

    @Test
    fun `release validates DWARF symbol table and build id before Crashlytics generation or upload`() {
        val validation = registeredTaskBlock("validateMartenCoreCrashlyticsSymbols")
        assertTrue(
            findCodeMatch(
                Regex("""(?m)^\s*dependsOn\s*\(\s*extractMartenCoreCrashlyticsSymbols\s*\)\s*$"""),
                validation,
            ) != null,
        )
        assertTrue(
            "validation must inspect the exact extracted native library",
            findCodeMatch(
                Regex(
                    """(?m)^\s*def\s+nativeLibrary\s*=\s*file\s*\(\s*[\"']\${'$'}martenCoreCrashlyticsSymbolsDir/jni/arm64-v8a/libmarten-core\.so[\"']\s*\)\s*$""",
                ),
                validation,
            ) != null,
        )
        assertTrue(
            "a missing extracted library must fail the build",
            findCodeMatch(
                Regex(
                    """if\s*\(\s*!nativeLibrary\.isFile\s*\(\s*\)\s*\)\s*\{\s*throw\s+new\s+GradleException""",
                    RegexOption.DOT_MATCHES_ALL,
                ),
                validation,
            ) != null,
        )
        assertTrue(
            findCodeMatch(
                Regex("""(?m)^\s*include\s+[\"']toolchains/llvm/prebuilt/\*/bin/llvm-readelf\*[\"']\s*$"""),
                validation,
            ) != null,
        )
        assertTrue(
            "missing llvm-readelf must fail closed",
            findCodeMatch(
                Regex(
                    """if\s*\(\s*readelf\s*==\s*null\s*\)\s*\{\s*throw\s+new\s+GradleException""",
                    RegexOption.DOT_MATCHES_ALL,
                ),
                validation,
            ) != null,
        )
        assertTrue(
            "llvm-readelf failures must fail the build",
            findCodeMatch(
                Regex(
                    """if\s*\(\s*process\.waitFor\s*\(\s*\)\s*!=\s*0\s*\)\s*\{\s*throw\s+new\s+GradleException""",
                    RegexOption.DOT_MATCHES_ALL,
                ),
                validation,
            ) != null,
        )
        assertTrue(
            "both DWARF and the ELF symbol table are required",
            findCodeMatch(
                Regex(
                    """inspect\s*\(\s*[\"']-S[\"']\s*\)[\s\S]*!sections\.contains\s*\(\s*[\"']\.debug_info[\"']\s*\)[\s\S]*!sections\.contains\s*\(\s*[\"']\.symtab[\"']\s*\)[\s\S]*throw\s+new\s+GradleException""",
                ),
                validation,
            ) != null,
        )
        assertTrue(
            "the native build ID is required for Crashlytics matching",
            findCodeMatch(
                Regex(
                    """!inspect\s*\(\s*[\"']-n[\"']\s*\)\.contains\s*\(\s*[\"']NT_GNU_BUILD_ID[\"']\s*\)[\s\S]*throw\s+new\s+GradleException""",
                ),
                validation,
            ) != null,
        )

        val (matching, configured) = crashlyticsMatchingConfigureEachBlocks()
        assertTrue(
            findCodeMatch(
                Regex("""it\.name\s*==\s*[\"']generateCrashlyticsSymbolFileRelease[\"']"""),
                matching,
            ) != null,
        )
        assertTrue(
            findCodeMatch(
                Regex("""it\.name\s*==\s*[\"']uploadCrashlyticsSymbolFileRelease[\"']"""),
                matching,
            ) != null,
        )
        assertTrue(
            "symbol generation and upload must wait for fail-closed validation",
            findCodeMatch(
                Regex("""(?m)^\s*dependsOn\s*\(\s*validateMartenCoreCrashlyticsSymbols\s*\)\s*$"""),
                configured,
            ) != null,
        )
    }

    @Test
    fun `release symbol upload is conditional on Firebase project configuration`() {
        assertTrue(
            "release upload hooks must be inside the optional Firebase configuration guard",
            buildScript.contains("if (hasFirebaseConfig) {\n    tasks.matching") &&
                hasAssembleReleaseUploadDependency(),
        )
    }

    private fun fileAssignment(name: String): String {
        val match = findCodeMatch(
            Regex(
                """(?m)^\s*def\s+${Regex.escape(name)}\s*=\s*file\s*\(\s*[\"']([^\"']+)[\"']\s*\)\s*$""",
            ),
            buildScript,
        )
        return requireNotNull(match?.groupValues?.get(1)) { "missing $name file assignment" }
    }

    private fun registeredTaskBlock(name: String): String {
        val declaration = findCodeMatch(
            Regex(
                """(?m)^\s*(?:def\s+\w+\s*=\s*)?tasks\.register\s*\(\s*[\"']${Regex.escape(name)}[\"'][^)]*\)\s*\{""",
            ),
            buildScript,
        )
        assertNotNull("missing registered task $name", declaration)
        return blockAt(buildScript, declaration!!.range.last)
    }

    private fun crashlyticsMatchingConfigureEachBlocks(): Pair<String, String> {
        val matchingPattern = Regex("""(?m)^\s*tasks\.matching\s*\{""")
        val configurePattern = Regex("""\.configureEach\s*\{""")
        var cursor = 0
        while (true) {
            val matchingCall = findCodeMatch(matchingPattern, buildScript, startIndex = cursor) ?: break
            val matching = blockAt(buildScript, matchingCall.range.last)
            val matchingEnd = matchingCall.range.last + matching.length
            val configureCall = findCodeMatch(configurePattern, buildScript, startIndex = matchingEnd)
            if (configureCall == null) {
                cursor = matchingEnd
                continue
            }
            val configured = blockAt(buildScript, configureCall.range.last)
            if (
                matching.contains("generateCrashlyticsSymbolFileRelease") &&
                    matching.contains("uploadCrashlyticsSymbolFileRelease")
            ) {
                return matching to configured
            }
            cursor = configureCall.range.last + configured.length
        }
        error("missing Crashlytics symbol task matching/configureEach block")
    }

    private fun hasAssembleReleaseUploadDependency(): Boolean {
        val directDependency = findCodeMatch(
            Regex(
                """(?m)^\s*(?:assembleRelease|bundleRelease)\.dependsOn\s*\(\s*uploadCrashlyticsSymbolFileRelease\s*\)\s*$""",
            ),
            buildScript,
        ) != null
        if (directDependency) return true

        val namedDependency = dependsOnInTaskNameConfiguration(
            Regex("""(?m)^\s*tasks\.named\(\s*['"](?:assembleRelease|bundleRelease)['"]\s*\)(?:\.configure)?\s*\{"""),
        )
        if (namedDependency) return true

        return hasLazyMatchingConfigureEachDependency()
    }

    private fun hasLazyMatchingConfigureEachDependency(): Boolean {
        val matchingCallPattern = Regex("""(?m)^\s*tasks\.matching\s*\{""")
        val configureEachPattern = Regex("""(?m)\.configureEach\s*\{""")
        val uploadDependencyPattern = Regex(
            """(?m)^\s*dependsOn\s*(?:\(\s*)?[\"']?uploadCrashlyticsSymbolFileRelease[\"']?(?:\s*\))?\s*$""",
        )
        var cursor = 0
        while (true) {
            val matchingCall = findCodeMatch(matchingCallPattern, buildScript, startIndex = cursor) ?: break
            val matching = blockAt(buildScript, matchingCall.range.last)
            val matchingEnd = matchingCall.range.last + matching.length
            val matchingHasReleaseVariants =
                matching.contains("assembleRelease") && matching.contains("bundleRelease")

            val configureCall = findCodeMatch(configureEachPattern, buildScript, startIndex = matchingEnd)
            if (configureCall == null) {
                cursor = matchingEnd
                continue
            }
            val configured = blockAt(buildScript, configureCall.range.last)

            val hasUploadDependency = configured.contains("dependsOn") && configured.contains("uploadCrashlyticsSymbolFileRelease")
            if (matchingHasReleaseVariants && hasUploadDependency) return true

            cursor = configureCall.range.last + configured.length
        }
        return false
    }

    private fun dependsOnInTaskNameConfiguration(taskPattern: Regex): Boolean {
        var cursor = 0
        while (true) {
            val declaration = findCodeMatch(taskPattern, buildScript, startIndex = cursor) ?: break
            val configured = blockAt(buildScript, declaration.range.last)
            cursor = declaration.range.last + configured.length
            val hasUploadDependency = findCodeMatch(
                Regex("""(?m)^\s*dependsOn\s*(?:\(\s*)?[\"']?uploadCrashlyticsSymbolFileRelease[\"']?(?:\s*\))?\s*$"""),
                configured,
            ) != null
            if (hasUploadDependency) return true
        }
        return false
    }

    private fun namedBlock(source: String, name: String): String {
        val declaration = findCodeMatch(Regex("""(?m)^\s*${Regex.escape(name)}\s*\{"""), source)
        assertNotNull("missing $name block", declaration)
        return blockAt(source, declaration!!.range.last)
    }

    private fun blockAt(source: String, bodyStart: Int): String {
        var depth = 0
        var index = bodyStart
        while (index < source.length) {
            when (source[index]) {
                '\'', '"' -> {
                    index = skipQuotedString(source, index)
                    continue
                }
                '{' -> depth++
                '}' -> {
                    depth--
                    if (depth == 0) return source.substring(bodyStart, index + 1)
                }
            }
            index++
        }
        error("block does not close")
    }

    private fun findCodeMatch(regex: Regex, source: String, startIndex: Int = 0): MatchResult? =
        regex.findAll(source, startIndex).firstOrNull { isCodePosition(source, it.range.first) }

    private fun isCodePosition(source: String, position: Int): Boolean {
        var index = 0
        while (index < position) {
            if (source[index] == '\'' || source[index] == '"') {
                val end = skipQuotedString(source, index)
                if (position < end) return false
                index = end
            } else {
                index++
            }
        }
        return true
    }

    private fun skipQuotedString(source: String, start: Int): Int {
        val quote = source[start]
        val triple = start + 2 < source.length && source[start + 1] == quote && source[start + 2] == quote
        var index = start + if (triple) 3 else 1
        while (index < source.length) {
            if (triple && index + 2 < source.length && source[index] == quote && source[index + 1] == quote && source[index + 2] == quote) {
                return index + 3
            }
            if (source[index] == '\\') {
                index += 2
                continue
            }
            if (!triple && source[index] == quote) return index + 1
            index++
        }
        error("unterminated quoted string")
    }

    private fun stripComments(source: String): String {
        val result = StringBuilder(source.length)
        var index = 0
        while (index < source.length) {
            when {
                source.startsWith("//", index) -> {
                    while (index < source.length && source[index] != '\n') {
                        result.append(' ')
                        index++
                    }
                }
                source.startsWith("/*", index) -> {
                    result.append("  ")
                    index += 2
                    while (index < source.length && !source.startsWith("*/", index)) {
                        result.append(if (source[index] == '\n') '\n' else ' ')
                        index++
                    }
                    check(index < source.length) { "unterminated build.gradle block comment" }
                    result.append("  ")
                    index += 2
                }
                source[index] == '\'' || source[index] == '"' -> {
                    val end = skipQuotedString(source, index)
                    result.append(source, index, end)
                    index = end
                }
                else -> {
                    result.append(source[index])
                    index++
                }
            }
        }
        return result.toString()
    }
}
