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

	var aura = CPUParticles2D.new()
	aura.name = "ReviverAura"
	aura.amount = 20
	aura.lifetime = 1.2
	aura.gravity = Vector2(0, -30)
	aura.emission_shape = CPUParticles2D.EMISSION_SHAPE_SPHERE
	aura.emission_sphere_radius = 35.0
	aura.local_coords = false # 让光环在走动时有拖拽感

	var grad = Gradient.new()
	grad.add_point(0.0, Color(0.0, 0.9, 0.2, 0.8))
	grad.add_point(1.0, Color(0.0, 0.9, 0.2, 0.0))
	aura.color_ramp = grad

	var curve = Curve.new()
	curve.add_point(Vector2(0, 0.5))
	curve.add_point(Vector2(0.5, 1.5))
	curve.add_point(Vector2(1, 0.0))
	aura.scale_amount_curve = curve
	aura.scale_amount_min = 5.0
	aura.scale_amount_max = 10.0

	visuals_node.add_child(aura)

func _physics_process(delta: float) -> void:
	if active_buff_timer > 0.0:
		active_buff_timer -= delta
	
	# 【核心修复】：如果正在受击闪红，暂停每帧的颜色覆盖！
	if _last_state == 7: # 7 是 State.HIT_STUN
		return

	if active_buff_timer > 0.0:
		if _player and _player._visuals:
			_player._visuals.modulate = Color(0.7, 1.2, 0.7) # 发绿
	else:
		if _player and _player._visuals:
			_player._visuals.modulate = Color(1.0, 1.0, 1.0)

# 本地释放大招时的预测与表现
func on_cast_ultimate() -> void:
	active_buff_timer = 15.0

# 复苏者专属动画逻辑：轻柔、施法感
func update_animation(current_state: int) -> void:
	if current_state == _last_state: return
	_last_state = current_state
	if not _body or not _weapon: return

	if _tween: _tween.kill()

	match current_state:
		0, 6: # IDLE, POST_CAST (缓慢呼吸)
			_tween = create_tween().set_loops().set_parallel(true)
			_tween.tween_property(_body, "scale:y", 0.98, 0.6).set_ease(Tween.EASE_IN_OUT)
			_tween.tween_property(_body, "scale:y", 1.0, 0.6).set_delay(0.6)
			_tween.tween_property(_weapon, "rotation_degrees", 0.0, 0.3)
		1, 2: # MOVE, CHARGING (轻盈飘动)
			_tween = create_tween().set_loops().set_parallel(true)
			_tween.tween_property(_body, "position:y", -4.0, 0.25).set_ease(Tween.EASE_OUT)
			_tween.tween_property(_body, "position:y", 0.0, 0.25).set_delay(0.25).set_ease(Tween.EASE_IN)
			_tween.tween_property(_weapon, "rotation_degrees", -15.0, 0.25)
			_tween.tween_property(_weapon, "rotation_degrees", 0.0, 0.25).set_delay(0.25)
		5, 4, 8: # PRE_CAST, ATTACK, SKILL_CAST (法杖小幅度点指)
			_tween = create_tween().set_parallel(true)
			_tween.tween_property(_weapon, "rotation_degrees", 60.0, 0.15).set_ease(Tween.EASE_OUT)
		7: # HIT_STUN
			_tween = create_tween().set_parallel(true)
			_visuals.modulate = Color(3.0, 0.2, 0.2)
			_tween.tween_property(_visuals, "scale", Vector2(0.85, 0.85), 0.1)
			_tween.tween_property(_visuals, "scale", Vector2(1.0, 1.0), 0.3).set_delay(0.1)
			get_tree().create_timer(0.2).timeout.connect(func(): _visuals.modulate = Color(1, 1, 1))
