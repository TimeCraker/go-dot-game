extends Camera2D

# 缩放限制配置 
var min_zoom: float = 0.6  # 离得最远时的视野
var max_zoom: float = 4.0  # 离得最近时的视野（提升特写倍数！）
var margin: Vector2 = Vector2(300.0, 300.0) 

# --- 新增：相机平滑速度配置 ---
var follow_speed: float = 15.0  # 把这个值调大，相机移动就越快（推荐 10-20）


func track_targets(players_dict: Dictionary, delta: float) -> void:
	if players_dict.is_empty():
		return
		
	var center_pos := Vector2.ZERO
	
	if players_dict.size() == 1:
		var only_p: Node2D = players_dict.values()[0] as Node2D
		global_position = global_position.lerp(only_p.global_position, 5.0 * delta)
		zoom = zoom.lerp(Vector2(max_zoom, max_zoom), 5.0 * delta)
		return
		
	var min_pos := Vector2(INF, INF)
	var max_pos := Vector2(-INF, -INF)

	for uid in players_dict:
		var p_node: Node2D = players_dict[uid] as Node2D
		var pos := p_node.global_position
		center_pos += pos
		
		# 使用强类型的 minf 和 maxf，消灭 Variant 报错
		min_pos.x = minf(min_pos.x, pos.x)
		min_pos.y = minf(min_pos.y, pos.y)
		max_pos.x = maxf(max_pos.x, pos.x)
		max_pos.y = maxf(max_pos.y, pos.y)

	center_pos /= players_dict.size()
	
	global_position = global_position.lerp(center_pos, 5.0 * delta)

	var rect_size := max_pos - min_pos 
	var screen_size := get_viewport_rect().size - margin 
	
	var zoom_x: float = screen_size.x / maxf(rect_size.x, 1.0)
	var zoom_y: float = screen_size.y / maxf(rect_size.y, 1.0)
	
	# 【彻底解决报错的地方】：强行指定为 float 并且使用 float 专用的数学函数
	var target_zoom_val: float = minf(zoom_x, zoom_y)
	target_zoom_val = clampf(target_zoom_val, min_zoom, max_zoom)
	
	var target_zoom := Vector2(target_zoom_val, target_zoom_val)
	
	zoom = zoom.lerp(target_zoom, 5.0 * delta)
