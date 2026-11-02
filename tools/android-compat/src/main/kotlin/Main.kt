import com.rahulislam.sensing.core.proto.Accuracy
import com.rahulislam.sensing.core.proto.DeviceKind
import com.rahulislam.sensing.core.proto.EventPayload
import com.rahulislam.sensing.core.proto.LocationPayload
import com.rahulislam.sensing.core.proto.QuatPayload
import com.rahulislam.sensing.core.proto.SampleBatch
import com.rahulislam.sensing.core.proto.ScalarPayload
import com.rahulislam.sensing.core.proto.SensorSample
import com.rahulislam.sensing.core.proto.TensorPayload
import com.rahulislam.sensing.core.proto.Vec3Payload
import com.rahulislam.sensing.storage.FrameCodec
import java.io.ByteArrayOutputStream
import java.io.File

// The Android side of scripts/compat.sh, using Android's real FrameCodec and Wire classes.
//
//   read PATH    prints the canonical lines of every chunk under PATH, sorted. Fails if a file doesn't verify to its end.
//   write DIR    writes Android-written fixtures, for Swift to read
//
// The canonical line is defined in Sources/SensingStorage/Canonical.swift.

private fun f32(v: Float) = "%08x".format(v.toRawBits())
private fun f64(v: Double) = "%016x".format(v.toRawBits())

private fun pct(s: String): String = buildString {
    for (b in s.toByteArray(Charsets.UTF_8)) {
        val u = b.toInt() and 0xff
        val c = u.toChar()
        if (u < 0x80 && (c.isLetterOrDigit() || c in "._-:/")) append(c) else append("%%%02x".format(u))
    }
}

fun canonical(s: SensorSample): String {
    val payload = when {
        s.vec3 != null -> s.vec3!!.let { "vec3 ${f32(it.x)} ${f32(it.y)} ${f32(it.z)}" }
        s.quat != null -> s.quat!!.let { "quat ${f32(it.x)} ${f32(it.y)} ${f32(it.z)} ${f32(it.w)} ${f32(it.heading_accuracy)}" }
        s.scalar != null -> "scalar ${f32(s.scalar!!.value_)}"
        s.location != null -> s.location!!.let {
            "location ${f64(it.lat)} ${f64(it.lon)} ${f64(it.alt)} ${f32(it.accuracy)} ${f32(it.speed)} ${f32(it.bearing)} ${pct(it.provider)} " +
                "${f32(it.vertical_accuracy)} ${f32(it.speed_accuracy)} ${f32(it.bearing_accuracy)} ${it.satellites.toUInt()} ${it.elapsed_realtime_uncertainty_ns}"
        }
        s.event != null -> s.event!!.let { e ->
            val attrs = e.attributes.map { "${pct(it.key)}=${pct(it.value)}" }.sorted().joinToString(",")
            "event ${pct(e.kind)} $attrs"
        }
        s.tensor != null -> s.tensor!!.let { t ->
            "tensor ${t.shape.joinToString(",") { it.toUInt().toString() }} ${t.values.joinToString(",") { f32(it) }} ${t.names.joinToString(",") { pct(it) }}"
        }
        else -> "none"
    }
    return listOf(pct(s.device_id), pct(s.session_id), pct(s.sensor_id), s.seq.toULong().toString(), s.ts_mono_ns.toString(), s.ts_wall_ms.toString(),
        s.schema_version.toUInt().toString(), s.accuracy.value.toString(), s.device_kind.value.toString(), payload).joinToString("|")
}

fun linesOf(file: File): List<String> =
    FrameCodec.readFrames(file.inputStream().buffered(), file.length()).flatMap { frame ->
        SampleBatch.ADAPTER.decode(FrameCodec.inflate(frame.payload)).samples.map(::canonical).asSequence()
    }.toList()

fun read(path: File) {
    val files = path.walkTopDown().filter { it.isFile && it.name.endsWith(".pb.gz") }.toList()
    check(files.isNotEmpty()) { "no chunks under $path" }
    for (f in files) {
        val good = f.inputStream().buffered().use { FrameCodec.scanValidPrefix(it, f.length()) }
        check(good == f.length()) { "${f.name}: only $good of ${f.length()} bytes verify" }
    }
    files.flatMap(::linesOf).sorted().forEach(::println)
    System.err.println("android-compat: read ${files.size} chunks")
}

private const val DEVICE = "aaaaaaaa-0000-4000-8000-0000000000a1"
private const val SESSION = "bbbbbbbb-0000-4000-8000-0000000000a2"

private fun base(sensor: String, seq: Long) = SensorSample(
    device_id = DEVICE, session_id = SESSION, sensor_id = sensor, seq = seq,
    ts_mono_ns = 300_000_000_000_000 + seq * 20_000_000, ts_wall_ms = 1_793_000_000_000 + seq * 20,
    schema_version = 1, accuracy = Accuracy.ACCURACY_HIGH, device_kind = DeviceKind.WATCH,
)

private fun chunk(vararg batches: SampleBatch): ByteArray =
    ByteArrayOutputStream().also { out -> batches.forEach { FrameCodec.writeFrame(out, SampleBatch.ADAPTER.encode(it)) } }.toByteArray()

fun write(dir: File) {
    dir.mkdirs()
    val accel = "motion.accelerometer"
    val v0 = SampleBatch(accel, (0L until 100).map { base(accel, it).copy(vec3 = Vec3Payload(0.1f * it, -9.80665f, 1e-30f)) })
    val v1 = SampleBatch(accel, (100L until 200).map { base(accel, it).copy(vec3 = Vec3Payload(0.1f * it, 9.80665f, 1e30f)) })
    File(dir, "${accel}_0.pb.gz").writeBytes(chunk(v0, v1))
    val q = "motion.rotation_vector"
    File(dir, "${q}_0.pb.gz").writeBytes(chunk(SampleBatch(q, listOf(base(q, 0).copy(quat = QuatPayload(0.5f, -0.5f, 0.25f, 0.625f, -1f), accuracy = Accuracy.ACCURACY_MEDIUM)))))
    val b = "env.barometer"
    File(dir, "${b}_0.pb.gz").writeBytes(chunk(SampleBatch(b, listOf(base(b, 0).copy(scalar = ScalarPayload(1000.50781f), accuracy = Accuracy.ACCURACY_UNRELIABLE)))))
    val l = "loc.gnss"
    File(dir, "${l}_0.pb.gz").writeBytes(chunk(SampleBatch(l, listOf(
        base(l, 0).copy(location = LocationPayload(40.712776123456789, -74.005974123456789, 10.5, 5f, 1.5f, 270f, "gps", 3f, 0.5f, 10f, 7, 123_456_789)),
        base(l, 1).copy(event = EventPayload("listening", mapOf("interval_ms" to "30000", "provider_enabled" to "true"))),
    ))))
    val t = "device.bluetooth_scan"
    File(dir, "${t}_0.pb.gz").writeBytes(chunk(SampleBatch(t, listOf(
        base(t, 0).copy(tensor = TensorPayload(listOf(2, 2), listOf(-60f, 127f, -71.5f, 4f), listOf("b57a3b2f7dad4b8a", "0123456789abcdef"))),
        base(t, 1).copy(tensor = TensorPayload(listOf(0, 2))),
    ))))
    val e = "device.session"
    File(dir, "${e}_0.pb.gz").writeBytes(chunk(SampleBatch(e, listOf(base(e, 0).copy(event = EventPayload("start", mapOf("reason" to "engine_start", "note" to "é=;,|% ok")))))))

    val good = dir.walkTopDown().filter { it.name.endsWith(".pb.gz") }.flatMap { linesOf(it).asSequence() }.toList().sorted()
    File(dir, "expected.txt").writeText(good.joinToString("\n") + "\n")

    // Damaged files go in a subfolder with their own expectation: the offset Android's own scanner says is valid.
    val damaged = File(dir, "damaged").apply { mkdirs() }
    val whole = chunk(v0, v1)
    val onlyFirst = chunk(v0)
    File(damaged, "torn.bin").writeBytes(whole.copyOf(whole.size - 7))
    File(damaged, "flipped.bin").writeBytes(whole.copyOf().also { it[it.size - 3] = (it[it.size - 3].toInt() xor 0x55).toByte() })
    val prefix = { f: String -> File(damaged, f).let { x -> x.inputStream().buffered().use { FrameCodec.scanValidPrefix(it, x.length()) } } }
    check(prefix("torn.bin") == prefix("flipped.bin"))
    File(damaged, "expected-prefix.txt").writeText("${prefix("torn.bin")} ${onlyFirst.size}\n")
    System.err.println("android-compat: wrote fixtures to $dir")
}

fun main(args: Array<String>) {
    require(args.size == 2) { "usage: read PATH | write DIR" }
    when (args[0]) {
        "read" -> read(File(args[1]))
        "write" -> write(File(args[1]))
        else -> error("usage: read PATH | write DIR")
    }
}
