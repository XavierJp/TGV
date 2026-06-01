package session

import (
	"context"
	"fmt"
	"strconv"
	"strings"
)

// HostMetrics is a snapshot of remote-server resource usage. Fields are
// best-effort: anything the probe couldn't fetch is left zero (or nil for
// optional pointers).
type HostMetrics struct {
	CPUPercent float64 // 0..1 — actual CPU utilization from /proc/stat delta
	CPUCount   int
	Load1      float64 // 1-minute load average

	MemUsed  uint64 // bytes
	MemTotal uint64

	DiskUsed  uint64 // root filesystem
	DiskTotal uint64

	CPUTemp *float64 // °C, nil if unavailable

	GPUUtil     *float64
	GPUMemUsed  *uint64
	GPUMemTotal *uint64
	GPUTemp     *float64
	GPUWatts    *float64
}

func (h *HostMetrics) MemFraction() float64 {
	if h == nil || h.MemTotal == 0 {
		return 0
	}
	return float64(h.MemUsed) / float64(h.MemTotal)
}

func (h *HostMetrics) DiskFraction() float64 {
	if h == nil || h.DiskTotal == 0 {
		return 0
	}
	return float64(h.DiskUsed) / float64(h.DiskTotal)
}

// HostMetrics runs a single SSH probe that gathers /proc/stat, meminfo, df,
// thermal, and (optional) nvidia-smi output. Computes CPU% from a 0.5s delta
// of /proc/stat. Same shape as the retired Swift Core/SessionManager.swift
// `hostMetrics()`.
func (m *Manager) HostMetrics(ctx context.Context) (*HostMetrics, error) {
	const probe = `echo "CPUSTAT1:$(grep '^cpu ' /proc/stat | head -1)"
sleep 0.5
echo "CPUSTAT2:$(grep '^cpu ' /proc/stat | head -1)"
echo "LOAD:$(cat /proc/loadavg 2>/dev/null)"
echo "CPUS:$(nproc 2>/dev/null)"
grep -E '^(MemTotal|MemAvailable):' /proc/meminfo 2>/dev/null | sed 's/^/MEM:/'
df -B1 / 2>/dev/null | tail -1 | awk '{print "DISK:"$2" "$3}'
if [ -f /sys/class/thermal/thermal_zone0/temp ]; then
  echo "CPUTEMP:$(cat /sys/class/thermal/thermal_zone0/temp)"
elif command -v sensors >/dev/null 2>&1; then
  echo "CPUTEMP:$(sensors 2>/dev/null | grep -i 'package\|tctl\|cpu' | head -1 | grep -oP '\+\K[0-9.]+'| head -1)000"
fi
if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw --format=csv,noheader,nounits 2>/dev/null | head -1 | sed 's/^/GPU:/'
fi`

	r, err := m.ssh.Exec(ctx, probe)
	if err != nil {
		return nil, err
	}

	var (
		h          HostMetrics
		memTotalKB uint64
		memAvailKB uint64
		stat1      []uint64
		stat2      []uint64
	)

	for _, raw := range strings.Split(r.Stdout, "\n") {
		line := strings.TrimSpace(raw)
		if line == "" {
			continue
		}

		switch {
		case strings.HasPrefix(line, "CPUSTAT1:"):
			stat1 = parseCPUStat(strings.TrimPrefix(line, "CPUSTAT1:"))
		case strings.HasPrefix(line, "CPUSTAT2:"):
			stat2 = parseCPUStat(strings.TrimPrefix(line, "CPUSTAT2:"))
		case strings.HasPrefix(line, "LOAD:"):
			payload := strings.TrimPrefix(line, "LOAD:")
			if first := strings.SplitN(payload, " ", 2)[0]; first != "" {
				h.Load1, _ = strconv.ParseFloat(first, 64)
			}
		case strings.HasPrefix(line, "CPUS:"):
			h.CPUCount, _ = strconv.Atoi(strings.TrimPrefix(line, "CPUS:"))
		case strings.HasPrefix(line, "MEM:"):
			payload := strings.TrimPrefix(line, "MEM:")
			parts := strings.SplitN(payload, ":", 2)
			if len(parts) != 2 {
				continue
			}
			key := strings.TrimSpace(parts[0])
			val := strings.TrimSuffix(strings.TrimSpace(parts[1]), " kB")
			kb, err := strconv.ParseUint(val, 10, 64)
			if err != nil {
				continue
			}
			switch key {
			case "MemTotal":
				memTotalKB = kb
			case "MemAvailable":
				memAvailKB = kb
			}
		case strings.HasPrefix(line, "DISK:"):
			parts := strings.Fields(strings.TrimPrefix(line, "DISK:"))
			if len(parts) >= 2 {
				h.DiskTotal, _ = strconv.ParseUint(parts[0], 10, 64)
				h.DiskUsed, _ = strconv.ParseUint(parts[1], 10, 64)
			}
		case strings.HasPrefix(line, "CPUTEMP:"):
			raw := strings.TrimPrefix(line, "CPUTEMP:")
			if v, err := strconv.ParseFloat(raw, 64); err == nil {
				if v > 1000 {
					v = v / 1000.0
				}
				h.CPUTemp = &v
			}
		case strings.HasPrefix(line, "GPU:"):
			parts := strings.Split(strings.TrimPrefix(line, "GPU:"), ",")
			for i := range parts {
				parts[i] = strings.TrimSpace(parts[i])
			}
			if len(parts) >= 1 {
				if util, err := strconv.ParseFloat(parts[0], 64); err == nil {
					f := util / 100.0
					if f < 0 {
						f = 0
					}
					if f > 1 {
						f = 1
					}
					h.GPUUtil = &f
				}
			}
			if len(parts) >= 3 {
				if used, err := strconv.ParseUint(parts[1], 10, 64); err == nil {
					b := used * 1024 * 1024
					h.GPUMemUsed = &b
				}
				if total, err := strconv.ParseUint(parts[2], 10, 64); err == nil {
					b := total * 1024 * 1024
					h.GPUMemTotal = &b
				}
			}
			if len(parts) >= 4 {
				if t, err := strconv.ParseFloat(parts[3], 64); err == nil {
					h.GPUTemp = &t
				}
			}
			if len(parts) >= 5 {
				if w, err := strconv.ParseFloat(parts[4], 64); err == nil {
					h.GPUWatts = &w
				}
			}
		}
	}

	// CPU% from /proc/stat delta.
	// Fields: user nice system idle iowait irq softirq steal guest guest_nice
	if len(stat1) >= 5 && len(stat2) >= 5 {
		var t1, t2 uint64
		for _, v := range stat1 {
			t1 += v
		}
		for _, v := range stat2 {
			t2 += v
		}
		idle1 := stat1[3] + stat1[4]
		idle2 := stat2[3] + stat2[4]
		if t2 > t1 {
			totalDelta := t2 - t1
			idleDelta := uint64(0)
			if idle2 > idle1 {
				idleDelta = idle2 - idle1
			}
			busy := uint64(0)
			if totalDelta > idleDelta {
				busy = totalDelta - idleDelta
			}
			if totalDelta > 0 {
				p := float64(busy) / float64(totalDelta)
				if p < 0 {
					p = 0
				}
				if p > 1 {
					p = 1
				}
				h.CPUPercent = p
			}
		}
	}

	h.MemTotal = memTotalKB * 1024
	if memTotalKB > memAvailKB {
		h.MemUsed = (memTotalKB - memAvailKB) * 1024
	}

	if h.MemTotal == 0 && h.DiskTotal == 0 && h.CPUCount == 0 {
		return nil, fmt.Errorf("host metrics probe returned no data")
	}
	return &h, nil
}

func parseCPUStat(line string) []uint64 {
	fields := strings.Fields(line)
	out := make([]uint64, 0, len(fields))
	for _, f := range fields {
		if v, err := strconv.ParseUint(f, 10, 64); err == nil {
			out = append(out, v)
		}
	}
	return out
}
