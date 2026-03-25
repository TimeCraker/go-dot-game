extends CharacterBody2D

# ===== 战斗与状态调参控制台 (需与服务端严格对齐) =====
const BASE_SPEED: float = 200.0
const CHARGE_SPEED_MULTIPLIER: float = 0.3
const MAX_CHARGE_TIME: float = 3.5
const MAX_EFFECTIVE_CHARGE_TIME: float = 2.5
const ACCEL_TIME: float = 1.33
const DASH_FRICTION: float = 18.0
const HIT_STUN_FRICTION: float = 8.0
const DASH_DIST_MULTIPLIER: float = 1.5

const DASH_DURATION: float = 0.3
const DASH_POST_CAST: float = 0.5
const ATTACK_PRE_CAST: float = 0.1
const ATTACK_DURATION: float = 0.05
const ATTACK_POST_CAST_MISS: float = 0.5
const ATTACK_POST_CAST_HIT: float = 0.3

const HIT_STUN_NORMAL: float = 0.4
const HIT_STUN_CLASH: float = 0.5
const KNOCKBACK_SPEED: float = 1600.0
const MELEE_RADIUS: float = 150.0
const DASH_HIT_RADIUS: float = 60.0

# --- 状态机：记录角色当前在做什么 ---
enum State { IDLE, MOVE, CHARGING, DASHING, ATTACK, PRE_CAST, POST_CAST, HIT_STUN, SKILL_CAST, DEAD }
var current_state: State = State.IDLE

var is_local_player: bool = false # 是否为玩家本人
var uid: int = 0                  # 玩家唯一ID
var hp: int = 100                 # 生命值

var target_pos: Vector2 = Vector2.ZERO # 网络同步的目标位置
var target_rot: float = 0.0            # 网络同步的目标旋转

var charge_timer: float = 0.0          # 计时器：记录按住左键了多久
var prediction_lock_timer: float = 0.0 # 预测锁：防止被旧的服务器快照错误拉回

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
		
# 处理玩家的操作指令
func _handle_local_input(delta: float) -> void:
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

	# --- 2. 鼠标左键 两段式蓄力逻辑 ---
	if can_move():
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			current_state = State.CHARGING
			charge_timer += delta
			
			# 【极限阈值】：捏了 3.5 秒，强制开火！
			if charge_timer >= MAX_CHARGE_TIME:
				_charge_pivot.hide()
				_execute_charge_dash()
			else:
				if not _charge_pivot.visible:
					_charge_pivot.show()
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
		
	# 处理视觉翻转
	if _visuals and can_move():
		if current_state == State.CHARGING:
			var mouse_x_diff: float = get_global_mouse_position().x - global_position.x
			if mouse_x_diff < 0: _visuals.scale.x = -1.0
			elif mouse_x_diff > 0: _visuals.scale.x = 1.0
		elif input_dir.x < 0.0: _visuals.scale.x = -1.0
		elif input_dir.x > 0.0: _visuals.scale.x = 1.0

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
	var mouse_pos := get_global_mouse_position()
	var dash_dir := (mouse_pos - global_position).normalized()
	
	# 初速度 = 距离 * 摩擦系数
	var initial_burst_speed: float = distance * DASH_FRICTION
	velocity += dash_dir * initial_burst_speed
	
	if _hitbox_area: _hitbox_area.monitoring = true
	if _hitbox_polygon: _hitbox_polygon.disabled = false
	_attack_hit_targets.clear()
	
	get_tree().create_timer(DASH_DURATION).timeout.connect(func(): 
		if current_state == State.DASHING:
			current_state = State.POST_CAST 
			if _hitbox_area: _hitbox_area.monitoring = false
			if _hitbox_polygon: _hitbox_polygon.disabled = true
			
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
			
			current_state = State.POST_CAST
			if _hitbox_area: _hitbox_area.monitoring = false
			if _hitbox_polygon: _hitbox_polygon.disabled = true
			
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
		_visuals.rotation = lerp_angle(_visuals.rotation, target_rot, 15.0 * delta)

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
		var face_x: float = 1.0 if _visuals.scale.x > 0 else -1.0
		push_dir = Vector2(face_x, 0.0)

	# 矩阵 A：绝对拼刀 (对方也在冲刺)
	if victim.current_state == State.DASHING:
		current_state = State.HIT_STUN
		velocity = push_dir * -KNOCKBACK_SPEED
		# 预测受害者的弹开 (往他自己原本冲刺的反方向)
		victim.current_state = State.HIT_STUN
		victim.velocity = victim.velocity.normalized() * -KNOCKBACK_SPEED

	# 矩阵 B：单方碾压
	else:
		current_state = State.POST_CAST
		velocity = Vector2.ZERO
		victim.current_state = State.HIT_STUN
		victim.velocity = push_dir * KNOCKBACK_SPEED

func update_network_state(px: float, pz: float, rot_y: float, server_state: int, server_hp: int, server_energy: int) -> void:
	hp = server_hp
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
			current_state = server_state
			global_position = server_pos # 【核心】强行拉回到服务器计算的被击退位置
			charge_timer = 0.0
			_input_buffer = ""
			if _charge_pivot != null: _charge_pivot.hide()
			if _hitbox_area != null: _hitbox_area.monitoring = false
			if _hitbox_polygon != null: _hitbox_polygon.disabled = true

		# 2. 【核心修复】状态解锁：如果本地还在硬直或后摇，但服务器说你已经自由了，立即解除锁定！
		elif current_state == State.HIT_STUN or current_state == State.POST_CAST:
			if server_state == State.IDLE or server_state == State.MOVE:
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
