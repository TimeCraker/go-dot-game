extends CharacterBody2D

# ==============================================================================
# 🎮 战斗与状态调参控制台 (Game Feel / Physics Tuning)
# 注意：以下所有物理与时间参数，必须与 Go 服务端 (player_state.go) 严格保持 1:1 对齐！
# ==============================================================================

# --- [移动与摩擦力系统] ---
const BASE_SPEED: float = 200.0               # 常规跑动满速 (像素/秒)
const CHARGE_SPEED_MULTIPLIER: float = 0.3    # 蓄力移速惩罚：0.3 代表按住左键时，移速降为正常的 30%
const ACCEL_TIME: float = 0.30                # 起步惯性：提速到满速需要的时间(秒)，体现肉感
const WEAPON_CHARGE_ROT: float = -35.0        # 蓄力时刀的旋转角度（负数为逆时针）
const DASH_FRICTION: float = 18.0             # 冲刺阻力：值越大，冲出去后刹车越快；值越小，滑行越远
const HIT_STUN_FRICTION: float = 8.0          # 受击摩擦力：值较小，体现被打飞后在地上痛苦滑行的平滑感

# --- [蓄力与冲刺突进系统] ---
const MAX_CHARGE_TIME: float = 3.5            # 强制过载：按住左键超过 3.5 秒，强制触发冲刺
const MAX_EFFECTIVE_CHARGE_TIME: float = 2.5  # 充能上限：最多只算 2.5 秒的收益，防止无限蓄力飞出地图
const DASH_DIST_MULTIPLIER: float = 1.5       # 距离放大器：决定蓄力时间转换成冲刺距离的“性价比”
const DASH_DURATION: float = 0.3              # 冲刺伤害判定窗口 (秒)
const DASH_POST_CAST: float = 0.5             # 冲刺结束后的“僵直喘息时间” (后摇)

# --- [普攻动作时间轴] ---
const ATTACK_PRE_CAST: float = 0.1            # 攻击前摇：按下攻击到实际挥出刀的短暂延迟
const ATTACK_DURATION: float = 0.05           # 伤害判定窗口：刀刃具有伤害的极短瞬间
const ATTACK_POST_CAST_MISS: float = 0.5      # 挥空惩罚：没砍中人时，自身陷入较长的收招硬直
const ATTACK_POST_CAST_HIT: float = 0.3       # 命中奖励：砍中人后，因为“卡肉”，收招硬直变短，方便连招

# --- [受击与击退系统] ---
const HIT_STUN_NORMAL: float = 0.4            # 普攻受击硬直：被平A砍中后无法动弹的时间
const HIT_STUN_CLASH: float = 0.5             # 拼刀受击硬直：互撞拼刀后，双方陷入更长的僵直
const KNOCKBACK_SPEED: float = 1600.0         # 击退初速度：被打飞瞬间的爆发速度 (配合摩擦力产生滑行)
const MELEE_RADIUS: float = 150.0             # 普攻扇形的有效砍击半径
const DASH_HIT_RADIUS: float = 60.0           # 冲刺时肉身撞击的碰撞判定半径

# --- [打击感视觉特效 (Screen Shake & Hit-Stop)] ---
const SHAKE_INTENSITY_CLASH: float = 30.0     # 拼刀震幅：发生拼刀时屏幕的剧烈撕裂程度
const SHAKE_INTENSITY_NORMAL: float = 15.0    # 普攻震幅：平A命中时的中度震动
const HIT_STOP_TIMESCALE: float = 0.05        # 卡肉定格：命中瞬间世界时间降至 5%，模拟刀刃卡在骨肉中的阻力
const HIT_STOP_DURATION_CLASH: float = 0.15   # 拼刀卡肉真实时长 (秒)
const HIT_STOP_DURATION_NORMAL: float = 0.08  # 普攻卡肉真实时长 (秒)

# --- 状态机：记录角色当前在做什么 ---
enum State { IDLE, MOVE, CHARGING, DASHING, ATTACK, PRE_CAST, POST_CAST, HIT_STUN, SKILL_CAST, DEAD }
var current_state: State = State.IDLE

var is_local_player: bool = false # 是否为玩家本人
var uid: int = 0                  # 玩家唯一ID
var hp: int = 100                 # 生命值
var energy: int = 0               # 终极技能能量值

var target_pos: Vector2 = Vector2.ZERO # 网络同步的目标位置
var target_rot: float = 0.0            # 网络同步的目标旋转

var charge_timer: float = 0.0          # 计时器：记录按住左键了多久
var prediction_lock_timer: float = 0.0 # 预测锁：防止被旧的服务器快照错误拉回
var role_mechanic: Node = null
var _q_pressed_last_frame: bool = false
var _my_class_id: String = ""

# --- 指令预输入系统 (Input Buffer) ---
var _input_buffer: String = ""    
var _buffer_timer: float = 0.0    
const BUFFER_MAX_TIME: float = 0.25 

@onready var _visuals: Node2D = $Visuals   
var _ui_container: Node2D = null  
var _name_label: Label = null              
var _hp_bar: ProgressBar = null            

var _hitbox_area: Area2D = null
var _hitbox_polygon: CollisionPolygon2D = null
var _attack_hit_targets: Array[CharacterBody2D] = []

var _charge_pivot: Node2D = null
var _move_joystick: VirtualJoystick = null
var _attack_joystick: VirtualJoystick = null
var _attack_joy_dir_cache: Vector2 = Vector2.ZERO
# ===== 新增：合并的视觉表现变量 =====
var _head: Node2D
var _body: Node2D
var _weapon: Node2D
var _trail: CPUParticles2D
var _role_tween: Tween
var active_buff_timer: float = 0.0
var _was_buffed: bool = false
var _last_anim_state: int = -1
# 新增：记住编辑器里的初始位置和缩放，防止动画让部件乱飞
var _base_head_pos_y: float = 0.0
var _base_body_scale: Vector2 = Vector2.ONE
var _base_weapon_pos_y: float = 0.0
var _base_weapon_rot: float = 0.0
var _base_visuals_scale_x: float = 1.0

func _ready() -> void:
	_build_dynamic_ui()              
	_build_hitbox_area()             
	_build_charge_indicator()        
	# 【强制挂载】绕过网络，强制在本节点初始化极速者特效
	_setup_integrated_visuals()
	if is_local_player:
		var mobile_controls := get_node_or_null("/root/Main/MobileControls")
		if mobile_controls:
			_move_joystick = mobile_controls.get_node_or_null("MoveJoystick") as VirtualJoystick
			_attack_joystick = mobile_controls.get_node_or_null("AttackJoystick") as VirtualJoystick
			mobile_controls.show()
			var gm := get_node_or_null("/root/GameManager")
			set_mobile_mode(gm.is_mobile if gm else false)

func set_mobile_mode(is_mobile: bool) -> void:
	if not is_local_player:
		return
	var mobile_controls := get_node_or_null("/root/Main/MobileControls")
	if mobile_controls:
		mobile_controls.show()
	_apply_joystick_scale(is_mobile)

func _apply_joystick_scale(from_js_mobile: bool) -> void:
	var os_mobile := OS.has_feature("mobile") or OS.has_feature("web_android") or OS.has_feature("web_ios")
	var use_large := os_mobile or from_js_mobile
	var s := 1.5 if use_large else 0.4
	if _move_joystick:
		_move_joystick.joystick_scale = s
	if _attack_joystick:
		_attack_joystick.joystick_scale = s

func can_move() -> bool:
	return current_state == State.IDLE or current_state == State.MOVE or current_state == State.CHARGING

func can_be_interrupted() -> bool:
	return current_state != State.SKILL_CAST and current_state != State.DEAD

# ==========================================
# 每帧 物理与移动处理
# ==========================================
func _physics_process(delta: float) -> void:
	if prediction_lock_timer > 0.0:
		prediction_lock_timer -= delta
	_ensure_ui_not_mirrored()
	
	if is_local_player:
		_handle_local_input(delta)
	else:
		_handle_remote_interpolation(delta)
	
	# 只要状态变了，就调用这个
	_update_role_animation(current_state)
	
	# --- 强制两人左右对望 (取代随鼠标翻转/旋转) ---
	if _visuals:
		_visuals.rotation = 0.0 # 本地也彻底干掉旋转
		var opponents = get_tree().get_nodes_in_group("players")
		for opp in opponents:
			if opp != self:
				# 如果对手在右边，我面朝右；对手在左，我面朝左
				if opp.global_position.x > global_position.x:
					_visuals.scale.x = abs(_visuals.scale.x) * _base_visuals_scale_x
				else:
					_visuals.scale.x = -abs(_visuals.scale.x) * _base_visuals_scale_x
				break
		
# 处理玩家的操作指令
func _handle_local_input(delta: float) -> void:
	# 开局冻结：等待 React 前端倒计时结束发送 startFight 信号
	var gm = get_node_or_null("/root/GameManager")
	if gm and not gm.is_fight_started:
		return

	# --- 0. 指令缓存 (Input Buffer) 倒计时与执行 ---
	if _buffer_timer > 0.0:
		_buffer_timer -= delta
		if _buffer_timer <= 0.0:
			_input_buffer = "" 
			
	if current_state == State.IDLE and _input_buffer == "attack":
		_input_buffer = ""
		_buffer_timer = 0.0
		_start_attack()

	var input_dir: Vector2 = Vector2.ZERO
	if _move_joystick and _move_joystick.is_pressed:
		input_dir = _move_joystick.output
		if input_dir != Vector2.ZERO:
			input_dir = input_dir.normalized()
	else:
		var left: bool = Input.is_physical_key_pressed(KEY_A) or Input.is_action_pressed("ui_left")
		var right: bool = Input.is_physical_key_pressed(KEY_D) or Input.is_action_pressed("ui_right")
		var up: bool = Input.is_physical_key_pressed(KEY_W) or Input.is_action_pressed("ui_up")
		var down: bool = Input.is_physical_key_pressed(KEY_S) or Input.is_action_pressed("ui_down")
		input_dir = Vector2(float(right) - float(left), float(down) - float(up)).normalized()
	
	# --- 1. 常规挥砍 (F 键 / 鼠标右键) ---
	var attack_just_pressed: bool = Input.is_action_just_pressed("attack") or Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT) or Input.is_physical_key_pressed(KEY_F)
	if attack_just_pressed:
		if can_move():
			_start_attack()
		else:
			_input_buffer = "attack"
			_buffer_timer = BUFFER_MAX_TIME

	# --- 大招触发 (Q 键单次触发防连发) ---
	var q_pressed: bool = Input.is_physical_key_pressed(KEY_Q)
	var q_just_pressed: bool = q_pressed and not _q_pressed_last_frame
	_q_pressed_last_frame = q_pressed

	if q_just_pressed and energy >= 15 and can_move():
		var ws = get_node_or_null("/root/BattleWsClient")
		if ws and ws.has_method("send_ultimate"):
			ws.send_ultimate()
			energy = 0
			current_state = State.SKILL_CAST
			active_buff_timer = 15.0
			AudioManager.play_sfx("ultimate", 2.0, false)

			# 【核心修复 1】本地预测大招释放前摇硬直 (0.1秒)，与 Go 服务端完美对齐
			get_tree().create_timer(0.1).timeout.connect(func():
				if current_state == State.SKILL_CAST:
					current_state = State.IDLE
			)

	var is_charging_mouse: bool = Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	var is_charging_joystick: bool = false
	var attack_dir: Vector2 = Vector2.ZERO
	if _attack_joystick and _attack_joystick.is_pressed:
		is_charging_joystick = true
		attack_dir = _attack_joystick.output
		if attack_dir != Vector2.ZERO:
			_attack_joy_dir_cache = attack_dir
	elif is_charging_mouse:
		_attack_joy_dir_cache = Vector2.ZERO
	var is_charging_now: bool = is_charging_mouse or is_charging_joystick

	# --- 2. 鼠标左键 / 右摇杆 两段式蓄力逻辑 ---
	if can_move():
		if is_charging_now:
			current_state = State.CHARGING
			var charge_rate: float = 1.5 if has_speed_buff() else 1.0
			charge_timer += delta * charge_rate
			
			# 【极限阈值】：捏了 3.5 秒，强制开火！
			if charge_timer >= MAX_CHARGE_TIME:
				_charge_pivot.hide()
				_execute_charge_dash(attack_dir)
			else:
				if not _charge_pivot.visible:
					_charge_pivot.show()
				
				if is_charging_joystick and attack_dir != Vector2.ZERO:
					_charge_pivot.rotation = attack_dir.angle()
				else:
					_charge_pivot.look_at(get_global_mouse_position())
				
				# 【有效时长】：距离计算最高封顶 2.5 秒
				var effective_time: float = minf(charge_timer, MAX_EFFECTIVE_CHARGE_TIME)
				var distance: float = effective_time * (BASE_SPEED * DASH_DIST_MULTIPLIER)
				_charge_pivot.scale.x = maxf(0.2, distance / 100.0)
			
		elif current_state == State.CHARGING and not is_charging_now:
			_charge_pivot.hide()
			var joy_release_aim: Vector2 = attack_dir
			if joy_release_aim == Vector2.ZERO:
				joy_release_aim = _attack_joy_dir_cache
			_attack_joy_dir_cache = Vector2.ZERO
			_execute_charge_dash(joy_release_aim)
			
		elif current_state != State.DASHING and current_state != State.POST_CAST:
			if input_dir != Vector2.ZERO:
				current_state = State.MOVE
			else:
				current_state = State.IDLE

	if not can_move():
		input_dir = Vector2.ZERO
		
	# --- 3. 双轨制速度算法 ---
	if current_state == State.HIT_STUN or current_state == State.DEAD:
		velocity = velocity.lerp(Vector2.ZERO, HIT_STUN_FRICTION * delta)
	elif current_state == State.DASHING:
		velocity = velocity.lerp(Vector2.ZERO, DASH_FRICTION * delta)
	else:
		# 轨道 B：常规移动 (起步快 1.5 倍)
		var current_max_speed: float = BASE_SPEED
		if current_state == State.CHARGING:
			current_max_speed = BASE_SPEED * CHARGE_SPEED_MULTIPLIER
			
		var target_velocity: Vector2 = input_dir * current_max_speed
		var accel_step: float = (BASE_SPEED / ACCEL_TIME) * delta
		
		var linear_target := Vector2.ZERO
		if input_dir == Vector2.ZERO:
			linear_target = velocity.move_toward(Vector2.ZERO, accel_step)
		else:
			if velocity != Vector2.ZERO and input_dir.dot(velocity.normalized()) < 0:
				accel_step *= 4.0 
			linear_target = velocity.move_toward(target_velocity, accel_step)
			
		velocity = velocity.lerp(linear_target, 25.0 * delta)

	move_and_slide()

	# 冲刺肉搏预测：纯数学距离检测，彻底告别物理穿模！
	if is_local_player and current_state == State.DASHING:
		for target in get_tree().get_nodes_in_group("players"):
			if target != self and target is CharacterBody2D:
				if global_position.distance_to(target.global_position) <= DASH_HIT_RADIUS:
					_predict_combat_hit(target)
					break

	# ===== 新增代码 START =====
	# 修改内容：将旧的坐标上报 send_move 升级为输入上报 send_input
	# 修改原因：服务端权威模式下，客户端只发送输入，坐标/状态由服务端回传
	# 影响范围：本地玩家每帧战斗网络上行
	var ws_client = get_node_or_null("/root/BattleWsClient")
	if ws_client:
		var mouse_pos: Vector2 = get_global_mouse_position()
		if is_charging_joystick and attack_dir != Vector2.ZERO:
			mouse_pos = global_position + (attack_dir * 100.0)
		var is_attacking_now: bool = (_input_buffer == "attack") or attack_just_pressed
		ws_client.send_input(
			input_dir.x,
			input_dir.y,
			is_charging_now,
			is_attacking_now,
			mouse_pos.x,
			mouse_pos.y
		)
	# ===== 新增代码 END =====

	# 新增大招光环维护
	if active_buff_timer > 0.0:
		active_buff_timer -= delta
		_was_buffed = true
		if _last_anim_state != 7 and _visuals:
			_visuals.modulate = Color(1.5, 0.5, 1.5)
	elif _was_buffed:
		_was_buffed = false
		if _last_anim_state != 7 and _visuals:
			_visuals.modulate = Color(1, 1, 1)

# ==========================================
# 蓄力突刺执行 (Left Click Release)
# ==========================================
func _execute_charge_dash(dash_dir_joystick: Vector2 = Vector2.ZERO) -> void:
	# 提取有效蓄力时间 (最高 2.5 秒) 计算最终距离
	var effective_time: float = minf(charge_timer, MAX_EFFECTIVE_CHARGE_TIME)
	var distance: float = effective_time * (BASE_SPEED * DASH_DIST_MULTIPLIER)
	charge_timer = 0.0 
	
	if distance < 10.0:
		current_state = State.IDLE
		return
		
	current_state = State.DASHING
	AudioManager.play_sfx("dash", 0.0)
	var dash_dir: Vector2
	if dash_dir_joystick != Vector2.ZERO:
		dash_dir = dash_dir_joystick.normalized()
	else:
		var mouse_pos: Vector2 = get_global_mouse_position()
		dash_dir = global_position.direction_to(mouse_pos)
	if dash_dir == Vector2.ZERO:
		dash_dir = Vector2(1.0 if _visuals.scale.x > 0 else -1.0, 0.0)
	
	# 初速度 = 距离 * 摩擦系数
	var initial_burst_speed: float = distance * DASH_FRICTION
	velocity += dash_dir * initial_burst_speed
	
	if _hitbox_area: _hitbox_area.monitoring = true
	if _hitbox_polygon: _hitbox_polygon.disabled = false
	_attack_hit_targets.clear()
	
	get_tree().create_timer(DASH_DURATION).timeout.connect(func():
		if current_state == State.DASHING:
			if _hitbox_area: _hitbox_area.monitoring = false
			if _hitbox_polygon: _hitbox_polygon.disabled = true

			if has_speed_buff():
				current_state = State.IDLE # 预测：完全取消后摇
			else:
				current_state = State.POST_CAST
				get_tree().create_timer(DASH_POST_CAST).timeout.connect(func():
					if current_state == State.POST_CAST:
						current_state = State.IDLE
				)
	)

# ==========================================
# 常规挥砍 (attack 动作 / 右键)
# ==========================================
func _start_attack() -> void:
	current_state = State.PRE_CAST
	get_tree().create_timer(ATTACK_PRE_CAST).timeout.connect(func() -> void:
		if current_state != State.PRE_CAST: return
		
		current_state = State.ATTACK
		if _hitbox_area: _hitbox_area.monitoring = true
		if _hitbox_polygon: _hitbox_polygon.disabled = false
		_attack_hit_targets.clear()
		
		get_tree().create_timer(ATTACK_DURATION).timeout.connect(func() -> void:
			if current_state != State.ATTACK: return
			if _hitbox_area: _hitbox_area.monitoring = false
			if _hitbox_polygon: _hitbox_polygon.disabled = true

			if has_speed_buff():
				current_state = State.IDLE # 预测：完全取消后摇
			else:
				current_state = State.POST_CAST
				get_tree().create_timer(ATTACK_POST_CAST_MISS).timeout.connect(func() -> void:
					if current_state != State.POST_CAST: return
					current_state = State.IDLE
				)
		)
	)

func _on_hitbox_body_entered(body: Node2D) -> void:
	if not (body is CharacterBody2D): return
	var cb: CharacterBody2D = body as CharacterBody2D
	if cb == self or cb in _attack_hit_targets: return
	
	_attack_hit_targets.append(cb)
	if is_local_player:
		_predict_combat_hit(cb)
	var victim_visuals: Node2D = cb.get_node_or_null("Visuals") as Node2D
	if victim_visuals:
		victim_visuals.modulate = Color(1, 0, 0)
		get_tree().create_timer(0.1).timeout.connect(func() -> void:
			if is_instance_valid(victim_visuals):
				victim_visuals.modulate = Color(1, 1, 1)
		)

func _handle_remote_interpolation(delta: float) -> void:
	global_position = global_position.lerp(target_pos, 15.0 * delta)
	if _visuals:
		_visuals.rotation = 0.0 # 彻底干掉远端旋转同步

# ==========================================
# 纯代码生成：蓄力指示箭头、UI、碰撞盒
# ==========================================
func _build_charge_indicator() -> void:
	_charge_pivot = Node2D.new()
	_charge_pivot.name = "ChargePivot"
	_charge_pivot.hide()

	# 1. 主体线段 (产生圆润、半透明的胶囊光束感)
	var body_line = Line2D.new()
	body_line.points = PackedVector2Array([Vector2(20, 0), Vector2(90, 0)])
	body_line.width = 12.0
	body_line.begin_cap_mode = Line2D.LINE_CAP_ROUND
	body_line.end_cap_mode = Line2D.LINE_CAP_ROUND

	# 添加高级渐变色 (发根淡紫粉透明 -> 头部淡淡的亮白)
	var grad = Gradient.new()
	grad.add_point(0.0, Color(0.8, 0.6, 0.9, 0.15))
	grad.add_point(1.0, Color(1.0, 1.0, 1.0, 0.75))
	body_line.gradient = grad

	# 2. 箭头头部 (利用圆角折线，打造干净利落的几何感)
	var head_line = Line2D.new()
	head_line.points = PackedVector2Array([Vector2(70, -14), Vector2(90, 0), Vector2(70, 14)])
	head_line.width = 12.0
	head_line.joint_mode = Line2D.LINE_JOINT_ROUND
	head_line.begin_cap_mode = Line2D.LINE_CAP_ROUND
	head_line.end_cap_mode = Line2D.LINE_CAP_ROUND
	head_line.default_color = Color(1.0, 1.0, 1.0, 0.9)

	# 将两根线组装进 Pivot (枢纽) 中
	_charge_pivot.add_child(body_line)
	_charge_pivot.add_child(head_line)
	add_child(_charge_pivot)

func _make_attack_fan_polygon() -> PackedVector2Array:
	var pts: PackedVector2Array = PackedVector2Array()
	pts.append(Vector2.ZERO)
	var step_deg: float = 10.0
	var ang_deg: float = -60.0
	while ang_deg <= 60.0 + 0.001:
		var rad: float = deg_to_rad(ang_deg)
		pts.append(Vector2(cos(rad), sin(rad)) * MELEE_RADIUS)
		ang_deg += step_deg
	return pts

func _build_hitbox_area() -> void:
	if _visuals == null: return
	_hitbox_area = Area2D.new()
	_hitbox_area.name = "HitboxArea"
	_hitbox_area.monitoring = false
	_hitbox_area.monitorable = false
	_visuals.add_child(_hitbox_area)

	_hitbox_polygon = CollisionPolygon2D.new()
	_hitbox_polygon.name = "HitboxFan"
	_hitbox_polygon.disabled = true
	_hitbox_polygon.polygon = _make_attack_fan_polygon()
	_hitbox_area.add_child(_hitbox_polygon)
	_hitbox_area.body_entered.connect(_on_hitbox_body_entered)

func _build_dynamic_ui() -> void:
	_ui_container = Node2D.new()
	_ui_container.name = "UI"
	add_child(_ui_container)

	_name_label = Label.new()
	_name_label.name = "NameLabel"
	if is_local_player:
		var local_name: String = GameManager.username
		if local_name == "": local_name = "Unknown"
		_name_label.text = local_name
		_name_label.modulate = Color(0.2, 0.8, 1.0)
	else:
		_name_label.text = "Enemy_" + str(uid)
		_name_label.modulate = Color(1.0, 0.2, 0.2)
	_name_label.position = Vector2(-50.0, -120.0)
	_ui_container.add_child(_name_label)

	_hp_bar = ProgressBar.new()
	_hp_bar.name = "HPBar"
	_hp_bar.min_value = 0
	_hp_bar.max_value = 100
	_hp_bar.value = hp
	_hp_bar.show_percentage = false
	_hp_bar.custom_minimum_size = Vector2(200.0, 10.0)
	_hp_bar.position = Vector2(-100.0, 130.0)

	var bg_style := StyleBoxFlat.new()
	bg_style.bg_color = Color(0.15, 0.02, 0.02)
	bg_style.border_color = Color(0.02, 0.02, 0.02)
	bg_style.border_width_left = 1
	bg_style.border_width_right = 1
	bg_style.border_width_top = 1
	bg_style.border_width_bottom = 1
	_hp_bar.add_theme_stylebox_override("background", bg_style)

	var fill_style := StyleBoxFlat.new()
	fill_style.bg_color = Color(0.2, 1.0, 0.2)
	_hp_bar.add_theme_stylebox_override("fill", fill_style)
	_ui_container.add_child(_hp_bar)

func _ensure_ui_not_mirrored() -> void:
	if _ui_container == null or _visuals == null: return
	var visuals_sign: float = abs(sign(_visuals.scale.x))
	if visuals_sign == 0.0: visuals_sign = 1.0
	_ui_container.scale.x = visuals_sign

func _predict_combat_hit(victim: CharacterBody2D) -> void:
	# 锁定本地状态 0.35 秒，等待服务器快照追上我们的进度
	prediction_lock_timer = 0.35
	# 【核心新增】：同时给受害者上锁，避免旧快照打断受击动画
	victim.prediction_lock_timer = 0.35

	# 强制清理本地攻击与蓄力状态
	charge_timer = 0.0
	_input_buffer = ""
	if _charge_pivot != null: _charge_pivot.hide()
	if _hitbox_area != null: _hitbox_area.monitoring = false
	if _hitbox_polygon != null: _hitbox_polygon.disabled = true

	# 确定我方（攻击者）的击退施加方向
	var push_dir: Vector2
	if current_state == State.DASHING:
		push_dir = velocity.normalized()
	else:
		# 【核心修复】：恢复本地预测时的 360 度鼠标击退方向
		var mouse_pos: Vector2 = get_global_mouse_position()
		push_dir = global_position.direction_to(mouse_pos)
		if push_dir == Vector2.ZERO:
			push_dir = Vector2(1.0 if _visuals.scale.x > 0 else -1.0, 0.0)

	# 矩阵 A：绝对拼刀 (对方也在冲刺)
	if victim.current_state == State.DASHING:
		_trigger_hit_feedback(true) # <--- 新增这行：触发拼刀极强反馈
		current_state = State.HIT_STUN
		velocity = push_dir * -KNOCKBACK_SPEED
		# 预测受害者的弹开 (往他自己原本冲刺的反方向)
		victim.current_state = State.HIT_STUN
		victim.velocity = victim.velocity.normalized() * -KNOCKBACK_SPEED

	# 矩阵 B：单方碾压
	else:
		_trigger_hit_feedback(false) # <--- 新增这行：触发普攻反馈
		current_state = State.POST_CAST
		velocity = Vector2.ZERO
		victim.current_state = State.HIT_STUN
		victim.velocity = push_dir * KNOCKBACK_SPEED

func update_network_state(px: float, pz: float, rot_y: float, server_state: int, server_hp: int, server_energy: int) -> void:
	# 无论是本地还是远端，只要血量能量变化，就带上 is_local 标识发给前端
	if hp != server_hp or energy != server_energy:
		var payload := {
			"is_local": is_local_player,
			"hp": server_hp,
			"energy": server_energy
		}
		var gm = get_node_or_null("/root/GameManager")
		if gm and gm.has_method("notify_react"):
			gm.notify_react("player_status", JSON.stringify(payload))

	hp = server_hp
	energy = server_energy
	if _hp_bar != null:
		_hp_bar.value = hp

	if is_local_player:
		# 【核心】如果处于预测锁定期，拒绝接受服务器的历史状态与坐标，相信本地物理！
		if prediction_lock_timer > 0.0:
			return

		var server_pos := Vector2(px, pz)
		var dist := global_position.distance_to(server_pos)

		# 1. 绝对权威覆写：不可控状态（硬直/被击退/死亡），必须瞬间服从服务端位置和状态！
		if server_state == State.HIT_STUN or server_state == State.DEAD:
			# <--- 新增这行：如果是刚刚进入受击状态，抖一下屏幕
			if current_state != server_state and server_state == State.HIT_STUN:
				_trigger_hit_feedback(false)

			current_state = server_state
			global_position = server_pos # 【核心】强行拉回到服务器计算的被击退位置
			charge_timer = 0.0
			_input_buffer = ""
			if _charge_pivot != null: _charge_pivot.hide()
			if _hitbox_area != null: _hitbox_area.monitoring = false
			if _hitbox_polygon != null: _hitbox_polygon.disabled = true

		# 2. 【核心修复】状态解锁：如果本地还在硬直、后摇或施法中，但服务器说你已经自由了，立即解除锁定！
		elif current_state == State.HIT_STUN or current_state == State.POST_CAST or current_state == State.SKILL_CAST:
			if server_state == State.IDLE or server_state == State.MOVE or server_state == State.CHARGING:
				current_state = server_state

		# 3. 轻量权威校正（防漂移）
		else:
			if dist > 200.0:
				# 误差大得离谱（比如客户端卡顿了一下，或者穿墙作弊），瞬间硬拉回
				global_position = server_pos

	else:
		# 【核心新增】：远端若处于预测锁定期，拒绝旧快照覆盖
		if prediction_lock_timer > 0.0:
			return
		# 远端玩家完全使用服务端权威状态推进动画与表现
		current_state = server_state
		target_pos = Vector2(px, pz)
		target_rot = deg_to_rad(rot_y)

func has_speed_buff() -> bool:
	return active_buff_timer > 0.0

# ==========================================
# 极速者视觉与动画系统 (已合并入 Player)
# ==========================================
func _setup_integrated_visuals() -> void:
	if not _visuals: return

	_head = _visuals.get_node_or_null("Head")
	_body = _visuals.get_node_or_null("Body")
	_weapon = _visuals.get_node_or_null("Weapon")
	_base_visuals_scale_x = sign(_visuals.scale.x)
	if _base_visuals_scale_x == 0.0: _base_visuals_scale_x = 1.0

	# 记录所有部件的基础 Transform，完美兼容镜像和编辑器偏移
	if _head: _base_head_pos_y = _head.position.y
	if _body: _base_body_scale = _body.scale
	if _weapon:
		_base_weapon_pos_y = _weapon.position.y
		_base_weapon_rot = _weapon.rotation_degrees

	# 特效优化：更细、水墨质感的拖尾
	_trail = CPUParticles2D.new()
	_trail.name = "InkTrail"
	_trail.amount = 30
	_trail.lifetime = 0.35
	_trail.gravity = Vector2.ZERO
	_trail.emission_shape = CPUParticles2D.EMISSION_SHAPE_SPHERE
	_trail.emission_sphere_radius = 5.0
	_trail.direction = Vector2(-1, 0)
	_trail.spread = 3.0
	_trail.initial_velocity_min = 40.0
	_trail.initial_velocity_max = 70.0
	_trail.local_coords = false

	var grad = Gradient.new()
	grad.add_point(0.0, Color(0.1, 0.1, 0.1, 0.8))
	grad.add_point(0.4, Color(0.4, 0.4, 0.4, 0.5))
	grad.add_point(1.0, Color(1.0, 1.0, 1.0, 0.0))
	_trail.color_ramp = grad

	var curve = Curve.new()
	curve.add_point(Vector2(0, 1.0))
	curve.add_point(Vector2(1, 0.0))
	_trail.scale_amount_curve = curve
	_trail.scale_amount_min = 1.0
	_trail.scale_amount_max = 3.5

	_visuals.add_child(_trail)
	_trail.emitting = false

func _update_role_animation(new_state: int) -> void:
	if new_state == _last_anim_state: return
	_last_anim_state = new_state

	if not _body or not _visuals: return
	if _role_tween: _role_tween.kill()

	match new_state:
		0, 6: # IDLE, POST_CAST (速度放慢 2 倍，头身极度和谐)
			if _trail: _trail.emitting = false
			_role_tween = create_tween().set_loops().set_parallel(true)
			_role_tween.tween_property(_body, "scale:y", _base_body_scale.y * 0.97, 0.8).set_ease(Tween.EASE_IN_OUT)
			_role_tween.tween_property(_body, "scale:y", _base_body_scale.y, 0.8).set_delay(0.8)

			if _head:
				_role_tween.tween_property(_head, "position:y", _base_head_pos_y + 1.5, 0.8).set_ease(Tween.EASE_IN_OUT)
				_role_tween.tween_property(_head, "position:y", _base_head_pos_y, 0.8).set_delay(0.8)
			if _weapon:
				_role_tween.tween_property(_weapon, "rotation_degrees", _base_weapon_rot, 0.8)

		1: # MOVE (普通移动)
			if _trail: _trail.emitting = true
			_role_tween = create_tween().set_loops().set_parallel(true)
			_role_tween.tween_property(_body, "scale:y", _base_body_scale.y * 1.03, 0.25)
			_role_tween.tween_property(_body, "scale:x", _base_body_scale.x * 0.97, 0.25)
			if _head:
				_role_tween.tween_property(_head, "position:y", _base_head_pos_y - 2.0, 0.25)

			_role_tween.tween_property(_body, "scale:y", _base_body_scale.y, 0.25).set_delay(0.25)
			_role_tween.tween_property(_body, "scale:x", _base_body_scale.x, 0.25).set_delay(0.25)
			if _head:
				_role_tween.tween_property(_head, "position:y", _base_head_pos_y, 0.25).set_delay(0.25)
			if _weapon:
				_role_tween.tween_property(_weapon, "rotation_degrees", _base_weapon_rot + 15.0, 0.25)

		2: # CHARGING (蓄力状态：缓慢平举武器)
			if _trail: _trail.emitting = true
			_role_tween = create_tween().set_parallel(true)
			_role_tween.tween_property(_body, "scale:y", _base_body_scale.y * 0.95, 0.6).set_ease(Tween.EASE_OUT)
			_role_tween.tween_property(_body, "scale:x", _base_body_scale.x * 1.02, 0.6)
			if _head:
				_role_tween.tween_property(_head, "position:y", _base_head_pos_y + 2.0, 0.6)
			if _weapon:
				_role_tween.tween_property(_weapon, "rotation_degrees", _base_weapon_rot + WEAPON_CHARGE_ROT, 1.5).set_ease(Tween.EASE_OUT)
		3: # DASHING
			if _trail: _trail.emitting = true
		7: # HIT_STUN (受击)
			if _trail: _trail.emitting = false
			_role_tween = create_tween().set_parallel(true)
			_visuals.modulate = Color(3.0, 0.2, 0.2)
			_role_tween.tween_property(_body, "scale", _base_body_scale * 0.8, 0.1)
			_role_tween.tween_property(_body, "scale", _base_body_scale, 0.3).set_delay(0.1)

			get_tree().create_timer(0.2).timeout.connect(func():
				if _last_anim_state == 7 and _visuals:
					_visuals.modulate = Color(1.5, 0.5, 1.5) if active_buff_timer > 0 else Color(1, 1, 1)
			)

# ==========================================
# 打击感反馈：卡肉顿帧 (Hit-Stop) & 屏幕震动
# ==========================================
func _trigger_hit_feedback(is_clash: bool) -> void:
	# 1. 触发屏幕震动
	var cam = get_viewport().get_camera_2d()
	if cam and cam.has_method("apply_shake"):
		cam.apply_shake(SHAKE_INTENSITY_CLASH if is_clash else SHAKE_INTENSITY_NORMAL)

	# 【新增音效】：根据是否拼刀播放不同的随机声音
	if is_clash:
		AudioManager.play_sfx("clash", 2.0)
	else:
		AudioManager.play_sfx("hit_flesh", 0.0)

	# 2. 触发卡肉顿帧 (若已处于绝杀特写 0.2 倍速，则不覆盖)
	if Engine.time_scale == 0.2: return

	Engine.time_scale = HIT_STOP_TIMESCALE
	var stop_duration: float = HIT_STOP_DURATION_CLASH if is_clash else HIT_STOP_DURATION_NORMAL

	# 创建真实世界时间的定时器
	get_tree().create_timer(stop_duration, true, false, true).timeout.connect(func():
		if Engine.time_scale == HIT_STOP_TIMESCALE:
			Engine.time_scale = 1.0
	)
