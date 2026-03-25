extends Node2D

var players: Dictionary = {}
var player_scene: PackedScene = preload("res://scene/player/player.tscn")
var local_player_spawned: bool = false
var initial_pos_sent: bool = false # 【保留字段】兼容旧逻辑，当前权威模式下不再发送初始坐标

@onready var group_camera = $GroupCamera 

func _ready() -> void:
	if not BattleWsClient.network_message.is_connected(_on_network_message):
		BattleWsClient.network_message.connect(_on_network_message)

func _process(delta: float) -> void:
	_check_and_spawn_local_player()
	# 服务端权威模式：本地位置不再主动上送，改由 Player 每帧上行输入指令
	if local_player_spawned and not initial_pos_sent:
		initial_pos_sent = true

	if group_camera != null:
		if group_camera.has_method("track_targets"):
			group_camera.track_targets(players, delta)

func _check_and_spawn_local_player() -> void:
	if local_player_spawned: return
	if not has_node("/root/GameManager"): return
	
	var gm := get_node("/root/GameManager")
	if gm != null and gm.user_id != 0:
		local_player_spawned = true
		var player: Node = player_scene.instantiate()
		player.is_local_player = true
		player.uid = gm.user_id
		player.add_to_group("players")
		add_child(player)
		players[gm.user_id] = player
		print("[Main] 本地玩家已部署，UID: ", gm.user_id)

func _on_network_message(msg: Dictionary) -> void:
	var msg_type: String = str(msg.get("type", ""))
	if msg_type == "state":
		# ===== 新增代码 START =====
		# 修改内容：接收服务端权威 state 快照并逐个玩家分发
		# 修改原因：从“直接同步坐标”升级为“服务端状态快照驱动”
		# 影响范围：战斗场景内所有玩家实体的网络状态刷新
		var gm = get_node_or_null("/root/GameManager")
		var state_players = msg.get("players", [])
		if state_players is Array:
			for raw_player in state_players:
				if not (raw_player is Dictionary):
					continue
				var p: Dictionary = raw_player
				var uid: int = int(p.get("user_id", 0))
				if uid == 0:
					continue

				# 若快照内玩家尚未实例化，立即补生成（支持晚进房/断线重连）
				if not players.has(uid):
					var instance: Node = player_scene.instantiate()
					instance.is_local_player = (gm != null and uid == int(gm.user_id))
					instance.uid = uid
					instance.add_to_group("players")
					add_child(instance)
					players[uid] = instance

				var player_node: Node = players[uid]
				var px: float = float(p.get("x", 0.0))
				var pz: float = float(p.get("z", 0.0))
				var rot_y: float = float(p.get("rot_y", 0.0))
				var server_state: int = int(p.get("current_state", 0))
				var server_hp: int = int(p.get("hp", 100))
				var server_energy: int = int(p.get("energy", 100))

				if player_node.has_method("update_network_state"):
					player_node.update_network_state(px, pz, rot_y, server_state, server_hp, server_energy)
		# ===== 新增代码 END =====
	elif msg_type == "opponent_left":
		var user_id: int = int(msg.get("user_id", 0))
		if players.has(user_id):
			var node: Node = players[user_id]
			players.erase(user_id)
			if is_instance_valid(node):
				node.queue_free()
