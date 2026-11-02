// The ingest's side of scripts/compat.sh. It's placed inside cloud/ingest/internal/server with `go test -overlay`, so
// it can call the ingest's real, unexported decoders without changing anything in that repo.
//
//	COMPAT_READ=DIR COMPAT_OUT=FILE   decodes every chunk under DIR through frames.Decode, rowsFor and projectLabels,
//	                                  and writes the canonical lines to FILE
//	COMPAT_WRITE=DIR                  writes Go-written fixtures with frames.Encode, for Swift to read
//
// The canonical line is defined in Sources/SensingStorage/Canonical.swift.
package server

import (
	"bytes"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	"google.golang.org/protobuf/proto"

	sensorlogv1 "github.com/SPICExLAB/inrtl-lab/cloud/ingest/gen/sensorlogv1"
	"github.com/SPICExLAB/inrtl-lab/cloud/ingest/internal/frames"
)

func f32(v float32) string { return fmt.Sprintf("%08x", math.Float32bits(v)) }
func f64(v float64) string { return fmt.Sprintf("%016x", math.Float64bits(v)) }

func pct(s string) string {
	var b strings.Builder
	for _, c := range []byte(s) {
		ok := c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || strings.IndexByte("._-:/", c) >= 0
		if ok {
			b.WriteByte(c)
		} else {
			fmt.Fprintf(&b, "%%%02x", c)
		}
	}
	return b.String()
}

func join[T any](xs []T, f func(T) string) string {
	out := make([]string, len(xs))
	for i, x := range xs {
		out[i] = f(x)
	}
	return strings.Join(out, ",")
}

func canonicalLine(s *sensorlogv1.SensorSample) string {
	var payload string
	switch p := s.GetPayload().(type) {
	case *sensorlogv1.SensorSample_Vec3:
		payload = fmt.Sprintf("vec3 %s %s %s", f32(p.Vec3.GetX()), f32(p.Vec3.GetY()), f32(p.Vec3.GetZ()))
	case *sensorlogv1.SensorSample_Quat:
		q := p.Quat
		payload = fmt.Sprintf("quat %s %s %s %s %s", f32(q.GetX()), f32(q.GetY()), f32(q.GetZ()), f32(q.GetW()), f32(q.GetHeadingAccuracy()))
	case *sensorlogv1.SensorSample_Scalar:
		payload = "scalar " + f32(p.Scalar.GetValue())
	case *sensorlogv1.SensorSample_Location:
		l := p.Location
		payload = fmt.Sprintf("location %s %s %s %s %s %s %s %s %s %s %d %d", f64(l.GetLat()), f64(l.GetLon()), f64(l.GetAlt()), f32(l.GetAccuracy()), f32(l.GetSpeed()), f32(l.GetBearing()),
			pct(l.GetProvider()), f32(l.GetVerticalAccuracy()), f32(l.GetSpeedAccuracy()), f32(l.GetBearingAccuracy()), l.GetSatellites(), l.GetElapsedRealtimeUncertaintyNs())
	case *sensorlogv1.SensorSample_Event:
		var attrs []string
		for k, v := range p.Event.GetAttributes() {
			attrs = append(attrs, pct(k)+"="+pct(v))
		}
		sort.Strings(attrs)
		payload = "event " + pct(p.Event.GetKind()) + " " + strings.Join(attrs, ",")
	case *sensorlogv1.SensorSample_Tensor:
		t := p.Tensor
		payload = "tensor " + join(t.GetShape(), func(v uint32) string { return fmt.Sprint(v) }) + " " + join(t.GetValues(), f32) + " " + join(t.GetNames(), pct)
	default:
		payload = "none"
	}
	return strings.Join([]string{pct(s.GetDeviceId()), pct(s.GetSessionId()), pct(s.GetSensorId()), fmt.Sprint(s.GetSeq()), fmt.Sprint(s.GetTsMonoNs()), fmt.Sprint(s.GetTsWallMs()),
		fmt.Sprint(s.GetSchemaVersion()), fmt.Sprint(int32(s.GetAccuracy())), fmt.Sprint(int32(s.GetDeviceKind())), payload}, "|")
}

// TestCompatRead sends Swift-written chunks through what a real commit runs.
func TestCompatRead(t *testing.T) {
	dir := os.Getenv("COMPAT_READ")
	if dir == "" {
		t.Skip("COMPAT_READ not set")
	}
	var lines []string
	var labels []LabelEvent
	chunks := 0
	err := filepath.Walk(dir, func(path string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() || !strings.HasSuffix(path, ".pb.gz") {
			return err
		}
		chunks++
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		res, err := frames.Decode(data)
		if err != nil {
			t.Errorf("%s: frames.Decode: %v", path, err)
			return nil
		}
		if res.Skipped != 0 {
			t.Errorf("%s: %d frames skipped", path, res.Skipped)
		}
		rows, ls, err := (&Server{}).rowsFor(&Chunk{ChunkID: filepath.Base(path)}, res, time.Now())
		if err != nil {
			t.Errorf("%s: rowsFor: %v", path, err)
			return nil
		}
		labels = append(labels, ls...)
		n := 0
		for _, f := range res.Frames {
			var b sensorlogv1.SampleBatch
			if err := proto.Unmarshal(f.Bytes, &b); err != nil {
				t.Errorf("%s: %v", path, err)
				continue
			}
			for _, s := range b.GetSamples() {
				lines = append(lines, canonicalLine(s))
				n++
			}
		}
		if n != len(rows) {
			t.Errorf("%s: %d samples but %d rows", path, n, len(rows))
		}
		for _, r := range rows {
			if r.PayloadType == "none" {
				t.Errorf("%s: seq %d has no payload", path, r.Seq)
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if chunks == 0 {
		t.Fatalf("no chunks under %s", dir)
	}
	sessions, lbls, skipped := projectLabels("uid-1", labels)
	if len(skipped) != 0 {
		t.Errorf("projectLabels skipped: %v", skipped)
	}
	t.Logf("%d chunks, %d samples; %d label events became %d session writes and %d label writes", chunks, len(lines), len(labels), len(sessions), len(lbls))
	sort.Strings(lines)
	if err := os.WriteFile(os.Getenv("COMPAT_OUT"), []byte(strings.Join(lines, "\n")+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
}

// TestCompatWrite makes fixtures with the ingest's own encoder.
func TestCompatWrite(t *testing.T) {
	dir := os.Getenv("COMPAT_WRITE")
	if dir == "" {
		t.Skip("COMPAT_WRITE not set")
	}
	const device, session = "aaaaaaaa-0000-4000-8000-0000000000b1", "bbbbbbbb-0000-4000-8000-0000000000b2"
	base := func(sensor string, seq uint64) *sensorlogv1.SensorSample {
		return &sensorlogv1.SensorSample{DeviceId: device, SessionId: session, SensorId: sensor, Seq: seq,
			TsMonoNs: 400_000_000_000_000 + int64(seq)*20_000_000, TsWallMs: 1_793_000_000_000 + int64(seq)*20, SchemaVersion: 1,
			Accuracy: sensorlogv1.Accuracy_ACCURACY_LOW, DeviceKind: sensorlogv1.DeviceKind_PHONE}
	}
	var samples []*sensorlogv1.SensorSample
	for i := uint64(0); i < 50; i++ {
		s := base("motion.gyroscope", i)
		s.Payload = &sensorlogv1.SensorSample_Vec3{Vec3: &sensorlogv1.Vec3Payload{X: float32(i) * 0.1, Y: -1.5, Z: 1e-30}}
		samples = append(samples, s)
	}
	ev := base("device.health", 0)
	ev.Payload = &sensorlogv1.SensorSample_Event{Event: &sensorlogv1.EventPayload{Kind: "heartbeat", Attributes: map[string]string{"reason": "periodic", "note": "é=;,|% ok"}}}
	write := func(name string, batches ...*sensorlogv1.SampleBatch) {
		var buf bytes.Buffer
		for _, b := range batches {
			raw, err := proto.Marshal(b)
			if err != nil {
				t.Fatal(err)
			}
			if err := frames.Encode(&buf, raw); err != nil {
				t.Fatal(err)
			}
		}
		if err := os.WriteFile(filepath.Join(dir, name), buf.Bytes(), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	write("motion.gyroscope_0.pb.gz", &sensorlogv1.SampleBatch{SensorId: "motion.gyroscope", Samples: samples[:25]}, &sensorlogv1.SampleBatch{SensorId: "motion.gyroscope", Samples: samples[25:]})
	write("device.health_0.pb.gz", &sensorlogv1.SampleBatch{SensorId: "device.health", Samples: []*sensorlogv1.SensorSample{ev}})
	var lines []string
	for _, s := range append(samples, ev) {
		lines = append(lines, canonicalLine(s))
	}
	sort.Strings(lines)
	if err := os.WriteFile(filepath.Join(dir, "expected.txt"), []byte(strings.Join(lines, "\n")+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
}
