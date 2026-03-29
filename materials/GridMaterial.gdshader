shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix;

uniform float tile_size : hint_range(0.1, 10.0) = 2.0;
uniform float line_thickness : hint_range(0.001, 0.1) = 0.02;
uniform vec4 line_color : source_color = vec4(1.0, 1.0, 1.0, 0.25);
uniform vec4 fill_color : source_color = vec4(0.0, 0.0, 0.0, 0.0);

void fragment() {
	vec3 world_pos = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec2 coord = vec2(world_pos.x, world_pos.z) / tile_size;
	vec2 grid = abs(fract(coord - 0.5) - 0.5) / fwidth(coord);
	float line = min(grid.x, grid.y);
	float alpha = 1.0 - min(line, 1.0);
	ALBEDO = mix(fill_color.rgb, line_color.rgb, alpha * line_color.a);
	ALPHA = mix(fill_color.a, line_color.a, alpha);
}