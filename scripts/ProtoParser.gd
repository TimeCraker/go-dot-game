extends RefCounted
class_name ProtoParser

# ===== 新增代码 START =====
# 修改内容：新增轻量级 Proto3 GameMessage 解码器（无第三方插件）
# 修改原因：客户端仅需解析特定字段并兼容未知字段跳过
# 影响范围：仅本解析脚本；供 BattleWsClient 收包后调用
static func decode_game_message(bytes: PackedByteArray) -> Dictionary:
	var buffer := StreamPeerBuffer.new()
	buffer.data_array = bytes
	buffer.seek(0)

	var result: Dictionary = {}

	while buffer.get_position() < buffer.get_size():
		var tag: int = _read_varint(buffer)
		var field_number: int = tag >> 3
		var wire_type: int = tag & 7

		match field_number:
			1:
				if wire_type == 2:
					var type_len: int = _read_varint(buffer)
					result["type"] = buffer.get_utf8_string(type_len)
				else:
					_skip_field(buffer, wire_type)
			2:
				if wire_type == 0:
					result["user_id"] = _read_varint(buffer)
				else:
					_skip_field(buffer, wire_type)
			3:
				if wire_type == 2:
					var content_len: int = _read_varint(buffer)
					result["content"] = buffer.get_utf8_string(content_len)
				else:
					_skip_field(buffer, wire_type)
			4:
				if wire_type == 5:
					result["x"] = buffer.get_float()
				else:
					_skip_field(buffer, wire_type)
			5:
				if wire_type == 5:
					result["y"] = buffer.get_float()
				else:
					_skip_field(buffer, wire_type)
			6:
				if wire_type == 5:
					result["z"] = buffer.get_float()
				else:
					_skip_field(buffer, wire_type)
			7:
				# 修改内容：补全 repeated PlayerPos 的长度前缀块解析
				# 修改原因：服务端 state 下行会把多个玩家快照塞到 players 字段中
				# 影响范围：战斗状态同步消息解析路径
				if wire_type == 2:
					var player_len: int = _read_varint(buffer)
					var end_pos: int = min(buffer.get_size(), buffer.get_position() + player_len)
					var player_dict: Dictionary = _decode_player_pos(buffer, end_pos)
					if not result.has("players"):
						result["players"] = []
					result["players"].append(player_dict)
				else:
					_skip_field(buffer, wire_type)
			9:
				if wire_type == 2:
					var room_id_len: int = _read_varint(buffer)
					result["room_id"] = buffer.get_utf8_string(room_id_len)
				else:
					_skip_field(buffer, wire_type)
			10:
				if wire_type == 5:
					result["rot_y"] = buffer.get_float()
				else:
					_skip_field(buffer, wire_type)
			11:
				if wire_type == 5:
					result["input_x"] = buffer.get_float()
				else:
					_skip_field(buffer, wire_type)
			12:
				if wire_type == 5:
					result["input_y"] = buffer.get_float()
				else:
					_skip_field(buffer, wire_type)
			13:
				if wire_type == 0:
					# bool 在 Proto3 中使用 varint 编码：0=false, 非0=true
					result["is_charging"] = _read_varint(buffer) != 0
				else:
					_skip_field(buffer, wire_type)
			14:
				if wire_type == 0:
					# bool 在 Proto3 中使用 varint 编码：0=false, 非0=true
					result["is_attacking"] = _read_varint(buffer) != 0
				else:
					_skip_field(buffer, wire_type)
			15:
				if wire_type == 5:
					result["mouse_x"] = buffer.get_float()
				else:
					_skip_field(buffer, wire_type)
			16:
				if wire_type == 5:
					result["mouse_y"] = buffer.get_float()
				else:
					_skip_field(buffer, wire_type)
			_:
				_skip_field(buffer, wire_type)

	return result


static func _decode_player_pos(buffer: StreamPeerBuffer, end_pos: int) -> Dictionary:
	# 修改内容：新增 PlayerPos 子消息解析器
	# 修改原因：players 为 length-delimited 嵌套消息，需要在子块内递归解析字段
	# 影响范围：BattleWsClient 收到 state 广播后的玩家快照落地
	var player: Dictionary = {}

	while buffer.get_position() < end_pos and buffer.get_position() < buffer.get_size():
		var tag: int = _read_varint(buffer)
		var field_number: int = tag >> 3
		var wire_type: int = tag & 7

		match field_number:
			1:
				if wire_type == 0:
					player["user_id"] = _read_varint(buffer)
				else:
					_skip_field(buffer, wire_type)
			2:
				if wire_type == 5:
					player["x"] = buffer.get_float()
				else:
					_skip_field(buffer, wire_type)
			3:
				if wire_type == 5:
					player["y"] = buffer.get_float()
				else:
					_skip_field(buffer, wire_type)
			4:
				if wire_type == 5:
					player["z"] = buffer.get_float()
				else:
					_skip_field(buffer, wire_type)
			5:
				if wire_type == 5:
					player["rot_y"] = buffer.get_float()
				else:
					_skip_field(buffer, wire_type)
			6:
				if wire_type == 0:
					player["current_state"] = _read_varint(buffer)
				else:
					_skip_field(buffer, wire_type)
			7:
				if wire_type == 0:
					player["hp"] = _read_varint(buffer)
				else:
					_skip_field(buffer, wire_type)
			8:
				if wire_type == 0:
					player["energy"] = _read_varint(buffer)
				else:
					_skip_field(buffer, wire_type)
			_:
				_skip_field(buffer, wire_type)

	# 防御性回拨到子消息结束位置，确保上层循环继续读取后续字段
	buffer.seek(end_pos)
	return player


static func _read_varint(buffer: StreamPeerBuffer) -> int:
	var value: int = 0
	var shift: int = 0

	while true:
		if buffer.get_position() >= buffer.get_size():
			return value

		var b: int = buffer.get_u8()
		value |= (b & 0x7F) << shift

		if (b & 0x80) == 0:
			break

		shift += 7
		if shift >= 64:
			break

	return value


static func _skip_field(buffer: StreamPeerBuffer, wire_type: int) -> void:
	match wire_type:
		0:
			_read_varint(buffer)
		1:
			buffer.seek(min(buffer.get_size(), buffer.get_position() + 8))
		2:
			var length: int = _read_varint(buffer)
			buffer.seek(min(buffer.get_size(), buffer.get_position() + length))
		5:
			buffer.seek(min(buffer.get_size(), buffer.get_position() + 4))
		_:
			# 未支持/非法 wire type，直接跳到末尾防止死循环
			buffer.seek(buffer.get_size())


static func encode_move_message(user_id: int, room_id: String, x: float, z: float, rot_y: float) -> PackedByteArray:
	var buffer := StreamPeerBuffer.new()

	_write_string_field(buffer, 1, "move")
	_write_varint_field(buffer, 2, user_id)
	_write_float_field(buffer, 4, x)
	_write_float_field(buffer, 5, 0.0)
	_write_float_field(buffer, 6, z)
	_write_string_field(buffer, 9, room_id)
	_write_float_field(buffer, 10, rot_y)

	return buffer.data_array


static func encode_input_message(user_id: int, room_id: String, input_x: float, input_y: float, is_charging: bool, is_attacking: bool, mouse_x: float, mouse_y: float) -> PackedByteArray:
	# 修改内容：新增输入同步消息编码方法（强类型字段按 Proto3 wire type 写入）
	# 修改原因：服务端权威模式下，客户端仅上行输入，服务端统一推进并广播状态
	# 影响范围：BattleWsClient 发送输入消息路径
	# 编码约定：
	# - varint(wire=0): user_id, bool 字段
	# - length-delimited(wire=2): type, room_id
	# - 32-bit(wire=5): input_x/input_y/mouse_x/mouse_y
	var buffer := StreamPeerBuffer.new()

	_write_string_field(buffer, 1, "input")
	_write_varint_field(buffer, 2, user_id)
	_write_string_field(buffer, 9, room_id)
	_write_float_field(buffer, 11, input_x)
	_write_float_field(buffer, 12, input_y)
	_write_varint_field(buffer, 13, int(is_charging))
	_write_varint_field(buffer, 14, int(is_attacking))
	_write_float_field(buffer, 15, mouse_x)
	_write_float_field(buffer, 16, mouse_y)

	return buffer.data_array


static func _write_varint(buffer: StreamPeerBuffer, value: int) -> void:
	var n: int = value
	if n < 0:
		n = 0
	while true:
		var byte_value: int = n & 0x7F
		n >>= 7
		if n != 0:
			buffer.put_u8(byte_value | 0x80)
		else:
			buffer.put_u8(byte_value)
			break


static func _write_varint_field(buffer: StreamPeerBuffer, field_number: int, value: int) -> void:
	var tag: int = (field_number << 3) | 0
	_write_varint(buffer, tag)
	_write_varint(buffer, value)


static func _write_string_field(buffer: StreamPeerBuffer, field_number: int, value: String) -> void:
	var tag: int = (field_number << 3) | 2
	var text_bytes: PackedByteArray = value.to_utf8_buffer()
	_write_varint(buffer, tag)
	_write_varint(buffer, text_bytes.size())
	buffer.put_data(text_bytes)


static func _write_float_field(buffer: StreamPeerBuffer, field_number: int, value: float) -> void:
	var tag: int = (field_number << 3) | 5
	_write_varint(buffer, tag)
	buffer.put_float(value)
# ===== 新增代码 END =====
