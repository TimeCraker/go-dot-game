extends Node

# 配置音效池 (支持同一种声音有多个变体)
var audio_pools: Dictionary = {
	"dash": [
		"res://assets/music/game/dash_1.wav",
		"res://assets/music/game/dash_2.wav"
	],
	"hit_flesh": [
		"res://assets/music/game/hit_1.wav",
		"res://assets/music/game/hit_2.wav",
		"res://assets/music/game/hit_3.wav"
	],
	"clash": [
		"res://assets/music/game/clash_1.wav"
	],
	"ultimate": [
		"res://assets/music/game/ultimate_1.wav"
	]
	# 如果以后有了挥空声，可以继续往这加: "swing": ["res://.../swing_1.wav"]
}

var _streams: Dictionary = {}

func _ready() -> void:
	# 启动时安全预加载所有音频变体
	for key in audio_pools:
		_streams[key] = []
		for path in audio_pools[key]:
			if ResourceLoader.exists(path):
				_streams[key].append(ResourceLoader.load(path))
			else:
				print("[AudioManager] 警告：找不到音效文件 -> ", path)

# 核心播放函数
func play_sfx(sound_name: String, volume_db: float = 0.0, randomize_pitch: bool = true) -> void:
	if not _streams.has(sound_name) or _streams[sound_name].is_empty():
		return

	# 【核心技巧】：在加载好的变体池中，随机抽取一个！
	var stream_array: Array = _streams[sound_name]
	var selected_stream = stream_array.pick_random()

	var player = AudioStreamPlayer.new()
	player.stream = selected_stream
	player.volume_db = volume_db
	player.bus = "Master"

	# 【听觉技巧】：微微随机改变音调，绝不单调
	if randomize_pitch:
		player.pitch_scale = randf_range(0.9, 1.1)

	add_child(player)
	player.play()
	player.finished.connect(player.queue_free)
