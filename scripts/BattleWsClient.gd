extends Node

# ===== 新增代码 START =====
# 修改内容：对外广播解码后的 GameMessage 字典
# 修改原因：场景层订阅网络状态并驱动实体
# 影响范围：仅信号定义与解码后派发
signal network_message(msg: Dictionary)
# ===== 新增代码 END =====

# ===== 新增代码 START =====
# 修改内容：WebSocket 基础客户端（建连 + 轮询 + 收包长度打印）
# 修改原因：里程碑 1 只打通网关通信基础，不做业务反序列化
# 影响范围：仅本单例脚本
var peer: WebSocketPeer = WebSocketPeer.new()
var _last_state: int = WebSocketPeer.STATE_CLOSED
# ===== 新增代码 END =====

func connect_to_server() -> void:
	# ===== 新增代码 START =====
	# 修改内容：从 GameManager 读取参数并拼接网关 URL
	# 修改原因：统一使用前端注入参数建立 battle scope 连接
	# 影响范围：仅连接发起流程
	if not has_node("/root/GameManager"):
		push_error("[BattleWsClient] 未找到 /root/GameManager")
		return

	var gm := get_node("/root/GameManager")
	var token: String = str(gm.token)
	var room_id: String = str(gm.room_id)
	var ws_base: String = str(gm.ws_base)

	if ws_base.is_empty():
		push_error("[BattleWsClient] ws_base 为空，无法连接")
		return

	var separator := "?"
	if ws_base.find("?") != -1:
		separator = "&"

	var url: String = ws_base + separator + "token=" + token.uri_encode() + "&scope=battle&roomId=" + room_id.uri_encode()

	var err := peer.connect_to_url(url)
	if err != OK:
		push_error("[BattleWsClient] connect_to_url 失败，err=%d" % err)
		return

	_last_state = WebSocketPeer.STATE_CONNECTING
	print("[BattleWsClient] 正在连接: ", url)
	# ===== 新增代码 END =====

func _process(_delta: float) -> void:
	# ===== 新增代码 START =====
	# 修改内容：轮询连接状态与读取二进制包
	# 修改原因：Godot WebSocketPeer 需要手动 poll 才能推进状态与收包
	# 影响范围：仅网络基础层；不做任何业务解码
	peer.poll()
	var state := peer.get_ready_state()

	if state == WebSocketPeer.STATE_OPEN and _last_state != WebSocketPeer.STATE_OPEN:
		print("[BattleWsClient] WebSocket 已连接")

	_last_state = state

	while peer.get_available_packet_count() > 0:
		var packet: PackedByteArray = peer.get_packet()
		print("[BattleWsClient] 收到二进制包，长度: ", packet.size())
		var msg_dict: Dictionary = ProtoParser.decode_game_message(packet)
		print("[BattleWsClient] 解码成功: ", msg_dict)
		network_message.emit(msg_dict)
	# ===== 新增代码 END =====


# ===== 新增代码 START =====
# 修改内容：删除旧的 send_move，改为输入指令上行 send_input
# 修改原因：客户端改为仅发送输入，位置与状态由服务端权威推进并回传
# 影响范围：battle 输入同步上行链路
func send_input(input_x: float, input_y: float, is_charging: bool, is_attacking: bool, mouse_x: float, mouse_y: float) -> void:
	# 连接未建立时直接忽略，避免无意义报错
	if peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	# 必须存在 GameManager 才能拿到 user_id 与 room_id
	if not has_node("/root/GameManager"):
		return

	var gm := get_node("/root/GameManager")
	var bytes: PackedByteArray = ProtoParser.encode_input_message(
		int(gm.user_id),
		str(gm.room_id),
		input_x,
		input_y,
		is_charging,
		is_attacking,
		mouse_x,
		mouse_y
	)
	peer.put_packet(bytes)
# ===== 新增代码 END =====


func send_ultimate() -> void:
	if peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	# 使用轻量级 JSON 消息触发大招，绕过繁琐的 Protobuf 重编译
	var json_str := '{"type":"cast_ultimate"}'
	peer.put_packet(json_str.to_utf8_buffer())
