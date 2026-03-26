extends Node

var active_buff_timer: float = 0.0
var _player: CharacterBody2D
var _visuals: Node2D
var _head: Node2D
var _body: Node2D
var _weapon: Node2D
var _last_state: int = -1
var _tween: Tween

func init_role(player_node: CharacterBody2D) -> void:
	_player = player_node

func apply_visuals(player: CharacterBody2D, visuals_node: Node2D) -> void:
	_visuals = visuals_node
	_head = _visuals.get_node_or_null("Head") as Node2D
	_body = _visuals.get_node_or_null("Body") as Node2D
	_weapon = _visuals.get_node_or_null("Weapon") as Node2D

	var trail = CPUParticles2D.new()
	trail.name = "SpeedsterTrail"
	trail.amount = 40 # 增加粒子数量让拖尾更连贯
	trail.lifetime = 0.5
	trail.gravity = Vector2.ZERO
	trail.emission_shape = CPUParticles2D.EMISSION_SHAPE_SPHERE
	trail.emission_sphere_radius = 20.0
	trail.direction = Vector2(-1, 0)
	trail.spread = 15.0
	trail.initial_velocity_min = 50.0
	trail.initial_velocity_max = 100.0
	trail.local_coords = false # 取消局部坐标，保留真实脱落拖尾

	var grad = Gradient.new()
	grad.add_point(0.0, Color(1.0, 0.7, 0.8, 1.0)) # 浅粉色
	grad.add_point(0.5, Color(0.8, 0.4, 0.9, 0.8)) # 粉紫色
	grad.add_point(1.0, Color(0.6, 0.1, 0.8, 0.0)) # 紫色透明
	trail.color_ramp = grad

	var curve = Curve.new()
	curve.add_point(Vector2(0, 1.0))
	curve.add_point(Vector2(1, 0.0))
	trail.scale_amount_curve = curve
	trail.scale_amount_min = 6.0
	trail.scale_amount_max = 12.0

	visuals_node.add_child(trail)

func _physics_process(delta: float) -> void:
	if active_buff_timer > 0.0:
		active_buff_timer -= delta
	
	# 【核心修复】：如果正在受击闪红，暂停每帧的颜色覆盖！
	if _last_state == 7: # 7 是 State.HIT_STUN
		return

	if active_buff_timer > 0.0:
		if _player and _player._visuals:
			_player._visuals.modulate = Color(1.5, 0.5, 1.5) # 发紫
	else:
		if _player and _player._visuals:
			_player._visuals.modulate = Color(1.0, 1.0, 1.0)

# 本地释放大招时的预测与表现
func on_cast_ultimate() -> void:
	active_buff_timer = 15.0

# 提供给宿主查询当前是否具有特殊状态
func has_speed_buff() -> bool:
	return active_buff_timer > 0.0

# 极速者专属动画逻辑：干脆、凌厉
func update_animation(current_state: int) -> void:
	if current_state == _last_state: return
	_last_state = current_state
	if not _body or not _weapon: return

	if _tween: _tween.kill()

	match current_state:
		0, 6: # IDLE, POST_CAST
			_tween = create_tween().set_loops().set_parallel(true)
			_tween.tween_property(_body, "scale:y", 0.95, 0.4).set_ease(Tween.EASE_IN_OUT)
			_tween.tween_property(_body, "scale:y", 1.0, 0.4).set_delay(0.4)
			_tween.tween_property(_weapon, "rotation_degrees", 0.0, 0.2)
		1, 2: # MOVE, CHARGING (快速奔跑弹跳)
			_tween = create_tween().set_loops().set_parallel(true)
			_tween.tween_property(_body, "scale:y", 1.05, 0.15)
			_tween.tween_property(_body, "scale:x", 0.95, 0.15)
			_tween.tween_property(_body, "scale:y", 1.0, 0.15).set_delay(0.15)
			_tween.tween_property(_body, "scale:x", 1.0, 0.15).set_delay(0.15)
			_tween.tween_property(_weapon, "position:y", -3.0, 0.15)
			_tween.tween_property(_weapon, "position:y", 0.0, 0.15).set_delay(0.15)
		5, 4, 8: # PRE_CAST, ATTACK, SKILL_CAST (大角度极速挥砍)
			_tween = create_tween().set_parallel(true)
			_tween.tween_property(_weapon, "rotation_degrees", 135.0, 0.1).set_ease(Tween.EASE_OUT)
		7: # HIT_STUN (闪红受击)
			_tween = create_tween().set_parallel(true)
			_visuals.modulate = Color(3.0, 0.2, 0.2)
			_tween.tween_property(_visuals, "scale", Vector2(0.8, 0.8), 0.1)
			_tween.tween_property(_visuals, "scale", Vector2(1.0, 1.0), 0.3).set_delay(0.1)
			get_tree().create_timer(0.2).timeout.connect(func(): _visuals.modulate = Color(1, 1, 1))
