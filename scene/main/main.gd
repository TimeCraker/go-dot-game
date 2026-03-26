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

		# 告诉 React 前端：场景已经完全加载并生成角色，可以撤下加载面板并开始倒计时了！
		if gm.has_method("notify_react"):
			gm.notify_react("engine_ready")

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
				var server_energy: int = int(p.get("energy", 0))

				if player_node.has_method("update_network_state"):
					player_node.update_network_state(px, pz, rot_y, server_state, server_hp, server_energy)
		# ===== 新增代码 END =====
	elif msg_type == "room_info":
		# 接收 Go 后端下发的双端职业情报
		var gm = get_node_or_null("/root/GameManager")
		if gm:
			if not ("room_classes" in gm):
				gm.set("room_classes", {}) # 动态防御机制
			
			var p1_id = int(msg.get("p1_id", 0))
			var p2_id = int(msg.get("p2_id", 0))
			if p1_id != 0: gm.room_classes[p1_id] = str(msg.get("p1_class", ""))
			if p2_id != 0: gm.room_classes[p2_id] = str(msg.get("p2_class", ""))
			
			# 情报到达，通知场景中已存在的玩家立刻加载职业组件 (MOD)
			for p_uid in players:
				if players[p_uid].has_method("apply_class_visuals"):
					players[p_uid].apply_class_visuals()
	elif msg_type == "game_over":
		# ===== 新增代码 START =====
		# 修改内容：拦截服务端 game_over 信号，触发子弹时间慢动作并在演出结束后通知 React
		# 修改原因：让客户端在胜负仲裁后播放 0.2 倍速结算特写，并在 1 秒（真实时间）后回调前端
		# 影响范围：仅影响 game_over 消息的演出与 UI 通知，不改变 state/opponent_left 分支行为
		var winner_id: int = int(msg.get("user_id", 0))
		print("[Main] 收到游戏结束信号，胜利者：", winner_id)

		# 1. 触发绝杀子弹时间 (全引擎 0.2 倍速慢动作)
		Engine.time_scale = 0.2

		# 2. 创建一个无视 time_scale 的真实世界定时器
		#    等待 1 秒真实时间（相当于慢动作下额外拉长演出观感）
		var timer := get_tree().create_timer(1.0, true, false, true)
		timer.timeout.connect(func():
			# 演出结束，恢复时间流速
			Engine.time_scale = 1.0

			# 将胜利者信息推给 React 网页
			var gm = get_node_or_null("/root/GameManager")
			if gm and gm.has_method("notify_react"):
				var payload := { "winner_id": winner_id }
				gm.notify_react("game_over", JSON.stringify(payload))
		)
		# ===== 新增代码 END =====
	elif msg_type == "opponent_left":
		var user_id: int = int(msg.get("user_id", 0))
		if players.has(user_id):
			var node: Node = players[user_id]
			players.erase(user_id)
			if is_instance_valid(node):
				node.queue_free()
