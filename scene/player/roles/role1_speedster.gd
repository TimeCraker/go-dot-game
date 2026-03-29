extends Node

var active_buff_timer: float = 0.0
var _was_buffed: bool = false
var _player: CharacterBody2D
var _visuals: Node2D
var _head: Node2D
var _body: Node2D
var _weapon: Node2D # 虽然这里不操作它旋转，但保留引用
var _last_state: int = -1
var _tween: Tween
var _trail: CPUParticles2D = null

func init_role(player_node: CharacterBody2D) -> void:
	_player = player_node

# 精准获取截图中的节点
func apply_visuals(player: CharacterBody2D, visuals_node: Node2D) -> void:
	_visuals = visuals_node
	# 使用 _visuals.get_node 干净地获取截图里对应的 Sprite2D
	_head = _visuals.get_node("Head") as Node2D
	_body = _visuals.get_node("Body") as Node2D
	_weapon = _visuals.get_node("Weapon") as Node2D

	# 纯代码动态生成渐变拖尾，杜绝 Null 崩溃报错
	_trail = CPUParticles2D.new()
	_trail.name = "SpeedsterTrail"
	_trail.amount = 40
	_trail.lifetime = 0.5
	_trail.gravity = Vector2.ZERO
	_trail.emission_shape = CPUParticles2D.EMISSION_SHAPE_SPHERE
	_trail.emission_sphere_radius = 20.0
	_trail.direction = Vector2(-1, 0)
	_trail.spread = 15.0
	_trail.initial_velocity_min = 50.0
	_trail.initial_velocity_max = 100.0
	_trail.local_coords = false

	var grad = Gradient.new()
	grad.add_point(0.0, Color(1.0, 0.7, 0.8, 1.0))
	grad.add_point(0.5, Color(0.8, 0.4, 0.9, 0.8))
	grad.add_point(1.0, Color(0.6, 0.1, 0.8, 0.0))
	_trail.color_ramp = grad

	var curve = Curve.new()
	curve.add_point(Vector2(0, 1.0))
	curve.add_point(Vector2(1, 0.0))
	_trail.scale_amount_curve = curve
	_trail.scale_amount_min = 6.0
	_trail.scale_amount_max = 12.0

	visuals_node.add_child(_trail)
	_trail.emitting = false

# 大招紫光Buff (非受击状态下覆盖)
func _physics_process(delta: float) -> void:
	if active_buff_timer > 0.0:
		active_buff_timer -= delta
		_was_buffed = true
		if _last_state != 7 and _visuals:
			_visuals.modulate = Color(1.5, 0.5, 1.5)
	else:
		if _was_buffed:
			_was_buffed = false
			if _last_state != 7 and _visuals:
				_visuals.modulate = Color(1.0, 1.0, 1.0)

# Q 技能接口
func on_cast_ultimate() -> void:
	active_buff_timer = 15.0

func has_speed_buff() -> bool:
	return active_buff_timer > 0.0

# 核心：使用现有的 Body, Head 节点做肉感动画，不碰武器旋转
func update_animation(current_state: int) -> void:
	if current_state == _last_state: return
	_last_state = current_state
	# 安全校验：防止节点还没加载时报错
	if not _body or not _head: return

	if _tween: _tween.kill()

	# 【重要 Debug】：我们不能 Tween "_visuals.scale:x" (会导致朝向错误)
	# 只能 Tween 它的子节点 _body, _head 来体现缩放。

	match current_state:
		0, 6: # IDLE, POST_CAST (呼吸动画)
			if _trail: _trail.emitting = false
			_tween = create_tween().set_loops().set_parallel(true)
			_tween.tween_property(_body, "scale:y", 0.95, 0.4).set_ease(Tween.EASE_IN_OUT)
			_tween.tween_property(_body, "scale:y", 1.0, 0.4).set_delay(0.4)
			_tween.tween_property(_head, "position:y", 1.0, 0.4).set_delay(0.4) # 头部跟随弹弹跳
		1, 2: # MOVE, CHARGING (快速奔跑弹跳)
			if _trail: _trail.emitting = true
			_tween = create_tween().set_loops().set_parallel(true)
			_tween.tween_property(_body, "scale:y", 1.05, 0.15)
			_tween.tween_property(_body, "scale:x", 0.95, 0.15)
			_tween.tween_property(_body, "scale:y", 1.0, 0.15).set_delay(0.15)
			_tween.tween_property(_body, "scale:x", 1.0, 0.15).set_delay(0.15)
		3: # DASHING
			if _trail: _trail.emitting = true
		7: # HIT_STUN (干净利落的受击闪红)
			if _trail: _trail.emitting = false
			_tween = create_tween().set_parallel(true)
			# 此状态由 player.gd 预测锁保护
			_visuals.modulate = Color(3.0, 0.2, 0.2)

			# 受击时不仅闪红，还把 Body squash 一下
			_tween.tween_property(_body, "scale", Vector2(0.8, 0.8), 0.1)
			_tween.tween_property(_body, "scale", Vector2(1.0, 1.0), 0.3).set_delay(0.1)

			get_tree().create_timer(0.2).timeout.connect(func():
				# 退出闪红时的 modulate 安全恢复
				if _last_state == 7 and _visuals:
					_visuals.modulate = Color(1.5, 0.5, 1.5) if active_buff_timer > 0 else Color(1.0, 1.0, 1.0)
			)
