extends CharacterBody2D

# ==============================================================================
# 🎮 战斗与状态调参控制台 (Game Feel / Physics Tuning)
# 注意：以下所有物理与时间参数，必须与 Go 服务端 (player_state.go) 严格保持 1:1 对齐！
# ==============================================================================

# --- [移动与摩擦力系统] ---
const BASE_SPEED: float = 200.0               # 常规跑动满速 (像素/秒)
const CHARGE_SPEED_MULTIPLIER: float = 0.3    # 蓄力移速惩罚：0.3 代表按住左键时，移速降为正常的 30%
const ACCEL_TIME: float = 1.33                # 起步惯性：提速到满速需要的时间(秒)，体现肉感
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

func _ready() -> void:
	_build_dynamic_ui()              
	_build_hitbox_area()             
	_build_charge_indicator()        
	apply_class_visuals()

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
	
	# 委托组件处理专属动画表现
	if role_mechanic and role_mechanic.has_method("update_animation"):
		role_mechanic.update_animation(current_state)
	
	# --- 强制两人左右对望 (取代随鼠标翻转/旋转) ---
	if _visuals:
		_visuals.rotation = 0.0 # 本地也彻底干掉旋转
		var opponents = get_tree().get_nodes_in_group("players")
		for opp in opponents:
			if opp != self:
				# 如果对手在右边，我面朝右；对手在左，我面朝左
				if opp.global_position.x > global_position.x:
					_visuals.scale.x = 1.0
				else:
					_visuals.scale.x = -1.0
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

	# --- 纯代码强绑 WASD 物理按键 (零配置直接生效) ---
	var left: bool = Input.is_physical_key_pressed(KEY_A) or Input.is_action_pressed("ui_left")
	var right: bool = Input.is_physical_key_pressed(KEY_D) or Input.is_action_pressed("ui_right")
	var up: bool = Input.is_physical_key_pressed(KEY_W) or Input.is_action_pressed("ui_up")
	var down: bool = Input.is_physical_key_pressed(KEY_S) or Input.is_action_pressed("ui_down")
	var input_dir: Vector2 = Vector2(float(right) - float(left), float(down) - float(up)).normalized()
	
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
			if role_mechanic and role_mechanic.has_method("on_cast_ultimate"):
				role_mechanic.on_cast_ultimate()

			# 【核心修复 1】本地预测大招释放前摇硬直 (0.1秒)，与 Go 服务端完美对齐
			get_tree().create_timer(0.1).timeout.connect(func():
				if current_state == State.SKILL_CAST:
					current_state = State.IDLE
			)

	# --- 2. 鼠标左键 两段式蓄力逻辑 ---
	if can_move():
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			current_state = State.CHARGING
			var charge_rate: float = 1.5 if role_mechanic and role_mechanic.has_method("has_speed_buff") and role_mechanic.has_speed_buff() else 1.0
			charge_timer += delta * charge_rate
			
			# 【极限阈值】：捏了 3.5 秒，强制开火！
			if charge_timer >= MAX_CHARGE_TIME:
				_charge_pivot.hide()
				_execute_charge_dash()
			else:
				if not _charge_pivot.visible:
					_charge_pivot.show()
				
				# 【核心修复】：恢复蓄力箭头 360 度跟随鼠标旋转
				_charge_pivot.look_at(get_global_mouse_position())
				
				# 【有效时长】：距离计算最高封顶 2.5 秒
				var effective_time: float = minf(charge_timer, MAX_EFFECTIVE_CHARGE_TIME)
				var distance: float = effective_time * (BASE_SPEED * DASH_DIST_MULTIPLIER)
				_charge_pivot.scale.x = maxf(0.2, distance / 100.0)
			
		elif current_state == State.CHARGING and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			_charge_pivot.hide()
			_execute_charge_dash()
			
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
		var is_charging_now: bool = Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
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

# ==========================================
# 蓄力突刺执行 (Left Click Release)
# ==========================================
func _execute_charge_dash() -> void:
	# 提取有效蓄力时间 (最高 2.5 秒) 计算最终距离
	var effective_time: float = minf(charge_timer, MAX_EFFECTIVE_CHARGE_TIME)
	var distance: float = effective_time * (BASE_SPEED * DASH_DIST_MULTIPLIER)
	charge_timer = 0.0 
	
	if distance < 10.0:
		current_state = State.IDLE
		return
		
	current_state = State.DASHING
	# 【核心修复】：恢复 360 度冲刺本地预测
	var mouse_pos: Vector2 = get_global_mouse_position()
	var dash_dir: Vector2 = global_position.direction_to(mouse_pos)
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

			if role_mechanic and role_mechanic.has_method("has_speed_buff") and role_mechanic.has_speed_buff():
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

			if role_mechanic and role_mechanic.has_method("has_speed_buff") and role_mechanic.has_speed_buff():
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
	
	var arrow = Polygon2D.new()
	arrow.color = Color(0.7, 0.2, 0.9, 0.25) 
	arrow.polygon = PackedVector2Array([
		Vector2(20, -6), Vector2(80, -6), Vector2(80, -18), 
		Vector2(120, 0), Vector2(80, 18), Vector2(80, 6), Vector2(20, 6)
	])
	_charge_pivot.add_child(arrow)
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
	_hp_bar.custom_minimum_size = Vector2(100.0, 12.0)
	_hp_bar.position = Vector2(-50.0, 58.0)

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
		# 远端玩家完全使用服务端权威状态推进动画与表现
		current_state = server_state
		target_pos = Vector2(px, pz)
		target_rot = deg_to_rad(rot_y)

# ==========================================
# 动态视觉 MOD 分发系统 (Component Pattern)
# ==========================================
func apply_class_visuals() -> void:
	var gm = get_node_or_null("/root/GameManager")
	if not gm or not gm.room_classes.has(uid): return

	var new_class_id: String = gm.room_classes[uid]
	if new_class_id == "": return

	if _my_class_id == new_class_id: return
	_my_class_id = new_class_id
	print("[Player] 角色 ", uid, " 准备加载视觉组件: ", _my_class_id)

	# 【终极修复】使用 preload 强制 Godot 将脚本打包进 Web 导出文件中
	var ComponentScript: Script = null
	match _my_class_id:
		"Role1_Speedster":
			ComponentScript = preload("res://scene/player/roles/role1_speedster.gd")
		"Role3_Reviver":
			ComponentScript = preload("res://scene/player/roles/role3_reviver.gd")

	if ComponentScript:
		var visual_comp = Node.new()
		visual_comp.name = _my_class_id + "_VisualComponent"
		visual_comp.set_script(ComponentScript)

		add_child(visual_comp)
		if visual_comp.has_method("init_role"):
			visual_comp.init_role(self)
		if visual_comp.has_method("apply_visuals"):
			visual_comp.apply_visuals(self, _visuals)
		role_mechanic = visual_comp
		print("[Player] 成功挂载视觉组件: ", _my_class_id)
	else:
		print("[Player] 警告：未匹配到对应的视觉组件 preload")

# ==========================================
# 打击感反馈：卡肉顿帧 (Hit-Stop) & 屏幕震动
# ==========================================
func _trigger_hit_feedback(is_clash: bool) -> void:
	# 1. 触发屏幕震动
	var cam = get_viewport().get_camera_2d()
	if cam and cam.has_method("apply_shake"):
		cam.apply_shake(SHAKE_INTENSITY_CLASH if is_clash else SHAKE_INTENSITY_NORMAL)

	# 2. 触发卡肉顿帧 (若已处于绝杀特写 0.2 倍速，则不覆盖)
	if Engine.time_scale == 0.2: return

	Engine.time_scale = HIT_STOP_TIMESCALE
	var stop_duration: float = HIT_STOP_DURATION_CLASH if is_clash else HIT_STOP_DURATION_NORMAL

	# 创建真实世界时间的定时器
	get_tree().create_timer(stop_duration, true, false, true).timeout.connect(func():
		if Engine.time_scale == HIT_STOP_TIMESCALE:
			Engine.time_scale = 1.0
	)
