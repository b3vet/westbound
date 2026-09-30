extends WBTest

func test_debug_sweep() -> void:
	for gain: float in [1.0, 1.5]:
		for fade: float in [1.5, 6.0]:
			var agg := PackedFloat64Array()
			for seed_value: int in [31, 32, 33]:
				var t := Tuning.load_default().duplicate() as Tuning
				t.net = t.net.duplicate() as NetTuning
				t.net.traffic_bias_gain = gain
				t.net.traffic_bias_fade_s = fade
				var r := NetTrafficRig.on_loop(seed_value, 500.0 + float(3000 * seed_value % 20000), 170.0, true, NetDelayLink.Mode.STREAM, true, t)
				r.bot.set_weave(3.0, 8.0)
				r.run(200.0)
				var s := r.stats()
				print("gain %.1f fade %.0f seed %d: mean %.3f p50 %.3f p99 %.3f max %.2f near p99 %.3f max %.2f" % [gain, fade, seed_value, s.mean_error(), s.percentile(0.5), s.percentile(0.99), s.err_max, s.percentile(0.99, true), s.err_near_max])
