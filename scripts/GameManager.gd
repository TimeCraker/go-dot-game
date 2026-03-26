extends Node

# ===== 新增代码 START =====
# 修改内容：战场入口全局参数（由 React 注入）
# 修改原因：迁移到 Godot 后，需要保留与 Unity EnterBattlePayload 对齐的数据结构
# 影响范围：仅本单例脚本的数据缓存与跨端桥接
var token: String = ""
var user_id: int = 0
var username: String = ""
var room_id: String = ""
var ws_base: String = ""
var selected_class: String = ""
var is_fight_started: bool = false

var _enter_battle_callback: JavaScriptObject = null
var _start_fight_callback: JavaScriptObject = null
# ===== 新增代码 END =====

func _ready() -> void:
	# ===== 新增代码 START =====
	# 修改内容：注册 window.enterBattle 回调给前端调用
	# 修改原因：React 侧通过 JSBridge 注入 battle 初始化参数
	# 影响范围：仅 Web 平台的 JS 交互入口
	if OS.has_feature("web"):
		var window: JavaScriptObject = JavaScriptBridge.get_interface("window")
		if window != null:
			_enter_battle_callback = JavaScriptBridge.create_callback(_on_enter_battle_from_react)
			window.enterBattle = _enter_battle_callback
			_start_fight_callback = JavaScriptBridge.create_callback(func(_args: Array):
				is_fight_started = true
				print("[GameManager] 收到前端 FIGHT 指令，战斗开始！")
			)
			window.startFight = _start_fight_callback
			print("[GameManager] window.enterBattle 已注册")
		else:
			push_warning("[GameManager] 无法获取 window 接口，enterBattle 未注册")
	else:
		push_warning("[GameManager] 当前非 Web 平台，跳过 JavaScriptBridge 注册")
	# ===== 新增代码 END =====

func _on_enter_battle_from_react(args: Array) -> void:
	# ===== 新增代码 START =====
	# 修改内容：解析前端传入 JSON，并触发 BattleWsClient 建连
	# 修改原因：完成跨端通信桥接最小闭环
	# 影响范围：仅参数注入与连接触发，不含任何实体/协议业务
	if args.is_empty():
		push_error("[GameManager] enterBattle 参数为空")
		return

	var payload_json := str(args[0])
	var parsed: Variant = JSON.parse_string(payload_json)

	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("[GameManager] enterBattle JSON 解析失败")
		return

	var data: Dictionary = parsed
	token = str(data.get("token", ""))
	user_id = int(data.get("userId", 0))
	# ===== 新增代码 START =====
	username = str(data.get("username", "Unknown"))
	# ===== 新增代码 END =====
	room_id = str(data.get("roomId", ""))
	ws_base = str(data.get("wsBase", ""))
	selected_class = str(data.get("selectedClass", ""))
	is_fight_started = false

	print("[GameManager] enterBattle 注入完成 user_id=", user_id, " room_id=", room_id)

	if has_node("/root/BattleWsClient"):
		var ws_client := get_node("/root/BattleWsClient")
		ws_client.connect_to_server()
	else:
		push_error("[GameManager] 未找到 /root/BattleWsClient，无法连接 WebSocket")
	# ===== 新增代码 END =====

func notify_react(result_type: String, payload_json: String = "{}") -> void:
	# ===== 新增代码 START =====
	# 修改内容：向前端抛出 unity:battle_result 事件
	# 修改原因：保持与原 WebGL jslib 通知语义一致
	# 影响范围：仅 JS 事件派发，不涉及游戏对象逻辑
	if not OS.has_feature("web"):
		push_warning("[GameManager] 非 Web 平台，notify_react 跳过")
		return

	var safe_result_type := JSON.stringify(result_type)
	var safe_payload := payload_json
	var js_code := (
		"(function(){"
		+ "try{"
		+ "var payload=" + safe_payload + ";"
		+ "window.parent.dispatchEvent(new CustomEvent('unity:battle_result',{detail:{resultType:" + safe_result_type + ",payload:payload}}));"
		+ "}catch(e){console.error('[GameManager] notify_react error',e);}"
		+ "})();"
	)

	JavaScriptBridge.eval(js_code)
	# ===== 新增代码 END =====
