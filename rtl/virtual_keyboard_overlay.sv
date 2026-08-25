module virtual_keyboard_overlay #(
	parameter integer PANEL_X = 4,
	parameter integer PANEL_Y = 94,
	parameter integer PANEL_WIDTH = 552,
	parameter integer PANEL_HEIGHT = 98
) (
	input  wire        clk,
	input  wire        reset,
	input  wire        active,
	input  wire        commands_page,
	input  wire [2:0]  selected_row,
	input  wire [3:0]  selected_col,
	input  wire        shift_latched,
	input  wire        control_latched,
	input  wire        caps_latched,
	input  wire        open_apple,
	input  wire        closed_apple,
	input  wire [1:0]  transparency,
	input  wire        overlay_top,
	input  wire        hblank,
	input  wire        vblank,
	input  wire [23:0] rgb_in,
	output reg         font_alternate,
	output reg         font_lowercase,
	output reg  [6:0]  font_character,
	output reg  [2:0]  font_row,
	input  wire [7:0]  font_data,
	output reg  [23:0] rgb_out
);

localparam [23:0] PANEL_COLOR = 24'hD0C4B1;
localparam [23:0] BORDER_COLOR = 24'hB8B8B0;
localparam [23:0] WELL_COLOR = 24'h686A65;
localparam [23:0] LINE_COLOR = 24'h4F504C;
localparam [23:0] KEY_COLOR = 24'h343633;
localparam [23:0] SELECT_COLOR = 24'h506D61;
localparam [23:0] LATCH_COLOR = 24'h8A7040;
localparam [23:0] TEXT_COLOR = 24'hF2EEE2;
localparam [23:0] INACTIVE_TEXT_COLOR = 24'h8F8C84;
localparam [23:0] ON_HOUSING_COLOR = 24'h656864;
localparam [23:0] ON_LIGHT_COLOR = 24'hA8D89A;

reg [9:0] video_x = 0;
reg [8:0] video_y = 0;
reg hblank_d = 1;

integer key_left;
integer key_top;
integer key_width;
integer key_height;
integer text_length;
integer text_left;
integer text_slot;
integer glyph_column;
integer glyph_y;
integer panel_y;
integer pixel_row;
integer pixel_col;
reg key_pixel;
reg panel_pixel;
reg border_pixel;
reg well_pixel;
reg separator_pixel;
reg selected_pixel;
reg latched_pixel;
reg glyph_pixel;
reg glyph_inactive;
reg label_pixel;
reg on_light_pixel;
reg on_light_lit_pixel;
reg [7:0] requested_character;

function automatic [7:0] key_character(input integer row, input integer col);
	begin
		key_character = 0;
		case(row)
			0: case(col)
				1: key_character = "1"; 2: key_character = "2";
				3: key_character = "3"; 4: key_character = "4";
				5: key_character = "5"; 6: key_character = "6";
				7: key_character = "7"; 8: key_character = "8";
				9: key_character = "9"; 10: key_character = "0";
				11: key_character = "-"; 12: key_character = "=";
				default: key_character = 0;
			endcase
			1: case(col)
				1: key_character = "Q"; 2: key_character = "W";
				3: key_character = "E"; 4: key_character = "R";
				5: key_character = "T"; 6: key_character = "Y";
				7: key_character = "U"; 8: key_character = "I";
				9: key_character = "O"; 10: key_character = "P";
				11: key_character = "["; 12: key_character = "]";
				default: key_character = 0;
			endcase
			2: case(col)
				1: key_character = "A"; 2: key_character = "S";
				3: key_character = "D"; 4: key_character = "F";
				5: key_character = "G"; 6: key_character = "H";
				7: key_character = "J"; 8: key_character = "K";
				9: key_character = "L"; 10: key_character = ";";
				11: key_character = "'"; 12: key_character = 8'h60;
				default: key_character = 0;
			endcase
			3: case(col)
				1: key_character = 7'h5C;
				2: key_character = "Z"; 3: key_character = "X";
				4: key_character = "C"; 5: key_character = "V";
				6: key_character = "B"; 7: key_character = "N";
				8: key_character = "M"; 9: key_character = ",";
				10: key_character = "."; 11: key_character = "/";
				default: key_character = 0;
			endcase
			default: key_character = 0;
		endcase
	end
endfunction

function automatic [7:0] shown_character(
	input integer row,
	input integer col,
	input shifted,
	input caps
);
	reg [7:0] code;
	begin
		code = key_character(row, col);
		shown_character = code;
		if(code >= "A" && code <= "Z") begin
			if(!(shifted ^ caps)) shown_character = code + 8'h20;
		end else if(row == 0 && shifted) begin
			case(col)
				1: shown_character = "!"; 2: shown_character = "@";
				3: shown_character = "#"; 4: shown_character = "$";
				5: shown_character = "%"; 6: shown_character = "^";
				7: shown_character = "&"; 8: shown_character = "*";
				9: shown_character = "("; 10: shown_character = ")";
				11: shown_character = "_"; 12: shown_character = "+";
				default: shown_character = code;
			endcase
		end else if(row == 1 && shifted) begin
			if(col == 11) shown_character = "{";
			else if(col == 12) shown_character = "}";
		end else if(row == 2 && shifted) begin
			if(col == 10) shown_character = ":";
			else if(col == 11) shown_character = 8'h22;
			else if(col == 12) shown_character = "~";
		end else if(row == 3 && shifted) begin
			if(col == 1) shown_character = "|";
			else if(col == 9) shown_character = "<";
			else if(col == 10) shown_character = ">";
			else if(col == 11) shown_character = "?";
		end
	end
endfunction

function automatic has_symbol_pair(input integer row, input integer col);
	begin
		has_symbol_pair = (row == 0 && col >= 1 && col <= 12) ||
			(row == 1 && (col == 11 || col == 12)) ||
			(row == 2 && (col >= 10 && col <= 12)) ||
			(row == 3 && (col == 1 || (col >= 9 && col <= 11)));
	end
endfunction

function automatic integer label_length(input integer row, input integer col, input commands);
	begin
		if(commands) label_length = 4;
		else if(row == 0 && (col == 0 || col == 13 || col == 14)) label_length = 3;
		else if(row == 1 && col == 0) label_length = 2;
		else if(row == 1 && col == 13) label_length = 1;
		else if(row == 2 && col == 0) label_length = 4;
		else if(row == 2 && col == 13) label_length = 2;
		else if(row == 3 && col == 0) label_length = 2;
		else if(row == 3 && col == 12) label_length = 5;
		else if(row == 4 && col == 0) label_length = 4;
		else if(row == 4 && ((col >= 1 && col <= 7) && col != 2)) label_length = 1;
		else if(row == 4 && col == 8) label_length = 1;
		else label_length = key_character(row, col) == 0 ? 0 : 1;
	end
endfunction

function automatic [7:0] label_character(
	input integer row,
	input integer col,
	input integer slot,
	input commands
);
	begin
		label_character = shown_character(row, col, shift_latched, caps_latched);
		if(commands) begin
			case(col)
				0: case(slot) 0: label_character="B"; 1: label_character="A"; 2: label_character="C"; default: label_character="K"; endcase
				1: case(slot) 0: label_character="W"; 1: label_character="A"; 2: label_character="R"; default: label_character="M"; endcase
				2: case(slot) 0: label_character="C"; 1: label_character="O"; 2: label_character="L"; default: label_character="D"; endcase
				default: case(slot) 0: label_character="T"; 1: label_character="E"; 2: label_character="S"; default: label_character="T"; endcase
			endcase
		end else if(row == 0 && col == 0) begin
			case(slot) 0: label_character="E"; 1: label_character="S"; default: label_character="C"; endcase
		end else if(row == 0 && col == 13) begin
			case(slot) 0: label_character="D"; 1: label_character="e"; default: label_character="l"; endcase
		end else if(row == 0 && col == 14) begin
			case(slot) 0: label_character="C"; 1: label_character="M"; default: label_character="D"; endcase
		end else if(row == 1 && col == 0) begin
			case(slot) 0: label_character=8'h55; default: label_character=8'h5F; endcase
		end else if(row == 1 && col == 13) begin
			label_character = 8'h4D;
		end else if(row == 2 && col == 0) begin
			case(slot) 0: label_character="C"; 1: label_character="t"; 2: label_character="r"; default: label_character="l"; endcase
		end else if(row == 2 && col == 13) begin
			if(slot == 0) label_character = 8'h47;
			else label_character = 8'h46;
		end else if(row == 3 && col == 0) begin
			case(slot) 0: label_character="S"; default: label_character="h"; endcase
		end else if(row == 3 && col == 12) begin
			case(slot) 0: label_character="S"; 1: label_character="h"; 2: label_character="i"; 3: label_character="f"; default: label_character="t"; endcase
		end else if(row == 4 && col == 0) begin
			case(slot) 0: label_character="C"; 1: label_character="a"; 2: label_character="p"; default: label_character="s"; endcase
		end else if(row == 4 && col == 1) begin
			label_character = 8'h41;
		end else if(row == 4 && col == 3) begin
			label_character = 8'h40;
		end else if(row == 4) begin
			case(col)
				4: label_character = 8'h48;
				5: label_character = 8'h55;
				6: label_character = 8'h4A;
				7: label_character = 8'h4B;
				default: label_character = 0;
			endcase
		end
	end
endfunction

function automatic diamond_pixel(
	input [2:0] x,
	input [2:0] y
);
	begin
		diamond_pixel = (y == 1 && x == 3) ||
			(y == 2 && (x == 2 || x == 4)) ||
			(y == 3 && (x == 1 || x == 5)) ||
			(y == 4 && (x == 2 || x == 4)) ||
			(y == 5 && x == 3);
	end
endfunction

function automatic [23:0] blend50(input [23:0] background, input [23:0] foreground);
	begin
		blend50[23:16] = {1'b0, background[23:17]} + {1'b0, foreground[23:17]};
		blend50[15:8] = {1'b0, background[15:9]} + {1'b0, foreground[15:9]};
		blend50[7:0] = {1'b0, background[7:1]} + {1'b0, foreground[7:1]};
	end
endfunction

function automatic [23:0] blend75(input [23:0] background, input [23:0] foreground);
	reg [9:0] red_sum;
	reg [9:0] green_sum;
	reg [9:0] blue_sum;
	begin
		red_sum = {2'b0, background[23:16]} + {1'b0, background[23:16], 1'b0} + {2'b0, foreground[23:16]};
		green_sum = {2'b0, background[15:8]} + {1'b0, background[15:8], 1'b0} + {2'b0, foreground[15:8]};
		blue_sum = {2'b0, background[7:0]} + {1'b0, background[7:0], 1'b0} + {2'b0, foreground[7:0]};
		blend75 = {red_sum[9:2], green_sum[9:2], blue_sum[9:2]};
	end
endfunction

function automatic [23:0] blend_color(
	input [23:0] background,
	input [23:0] foreground,
	input [1:0] mode
);
	begin
		case(mode)
			2: blend_color = blend75(background, foreground);
			3: blend_color = blend50(background, foreground);
			default: blend_color = foreground;
		endcase
	end
endfunction

always @(posedge clk) begin
	hblank_d <= hblank;
	if(reset || vblank) begin
		video_x <= 0;
		video_y <= 0;
	end else begin
		if(hblank) video_x <= 0;
		else video_x <= video_x + 1'd1;
		if(!hblank_d && hblank) video_y <= video_y + 1'd1;
	end
end

always @(*) begin
	key_pixel = 0;
	panel_pixel = 0;
	border_pixel = 0;
	well_pixel = 0;
	separator_pixel = 0;
	selected_pixel = 0;
	latched_pixel = 0;
	glyph_pixel = 0;
	glyph_inactive = 0;
	label_pixel = 0;
	on_light_pixel = 0;
	on_light_lit_pixel = 0;
	font_character = 0;
	font_row = 0;
	font_alternate = 0;
	font_lowercase = 0;
	requested_character = 0;
	pixel_row = 0;
	pixel_col = 0;
	key_left = 0;
	key_top = 0;
	key_width = 0;
	key_height = 0;
	text_length = 0;
	text_left = 0;
	text_slot = 0;
	glyph_column = 0;
	glyph_y = 0;
	panel_y = overlay_top ? 0 : PANEL_Y;

	if(active && !hblank && !vblank &&
		video_x >= PANEL_X && video_x < PANEL_X + PANEL_WIDTH &&
		video_y >= panel_y && video_y < panel_y + PANEL_HEIGHT) begin
		panel_pixel = video_x >= PANEL_X + 1 && video_x < PANEL_X + 551 &&
			video_y >= panel_y + 1 && video_y < panel_y + 97 &&
			!(((video_y == panel_y + 1 || video_y == panel_y + 96) &&
				(video_x < PANEL_X + 6 || video_x >= PANEL_X + 547)) ||
			  ((video_y == panel_y + 2 || video_y == panel_y + 95) &&
				(video_x == PANEL_X + 1 || video_x == PANEL_X + 550)));
		border_pixel = panel_pixel &&
			(video_y == panel_y + 1 || video_y == panel_y + 96 ||
			 video_x == PANEL_X + 1 || video_x == PANEL_X + 550);
		well_pixel = panel_pixel && video_x >= PANEL_X + 7 && video_x < PANEL_X + 478 &&
			video_y >= panel_y + 6 && video_y < panel_y + 90;
		separator_pixel = well_pixel && (video_y == panel_y + 22 || video_y == panel_y + 39 ||
			video_y == panel_y + 56 || video_y == panel_y + 73);
		if(commands_page) begin
			if(video_y >= panel_y + 32 && video_y < panel_y + 58) begin
				pixel_col = (video_x - (PANEL_X + 16)) >> 7;
				key_left = PANEL_X + 16 + (pixel_col << 7);
				key_top = panel_y + 32;
				key_width = 120;
				key_height = 26;
				key_pixel = pixel_col < 4 && video_x >= key_left && video_x < key_left + key_width;
				selected_pixel = pixel_col == selected_col;
			end
		end else if(video_y >= panel_y + 7 && video_y < panel_y + 89) begin
			key_height = 14;
			if(video_y >= panel_y + 24 && video_y < panel_y + 55 &&
				((video_y < panel_y + 39 && video_x >= PANEL_X + 424 && video_x < PANEL_X + 470) ||
				 (video_y >= panel_y + 39 && video_x >= PANEL_X + 446 && video_x < PANEL_X + 470))) begin
				pixel_row = 1; pixel_col = 13; key_left = PANEL_X + 424;
				key_top = panel_y + 24; key_width = 46; key_height = 31; key_pixel = 1;
			end else if(video_y < panel_y + 21) begin
				pixel_row = 0; key_top = panel_y + 7;
				if(video_x >= PANEL_X + 8 && video_x < PANEL_X + 422) begin
					pixel_col = (video_x - PANEL_X - 8) >> 5;
					key_left = PANEL_X + 8 + (pixel_col << 5);
					key_width = 30; key_pixel = video_x < key_left + 30;
				end else if(video_x >= PANEL_X + 424 && video_x < PANEL_X + 470) begin
					pixel_col = 13; key_left = PANEL_X + 424; key_width = 46; key_pixel = 1;
				end else if(video_x >= PANEL_X + 504 && video_x < PANEL_X + 544) begin
					pixel_col = 14; key_left = PANEL_X + 504; key_width = 40; key_pixel = 1;
				end
			end else if(video_y >= panel_y + 24 && video_y < panel_y + 38) begin
				pixel_row = 1; key_top = panel_y + 24;
				if(video_x >= PANEL_X + 8 && video_x < PANEL_X + 46) begin
					pixel_col = 0; key_left = PANEL_X + 8; key_width = 38; key_pixel = 1;
				end else if(video_x >= PANEL_X + 48 && video_x < PANEL_X + 422) begin
					pixel_col = 1 + ((video_x - PANEL_X - 48) >> 5);
					key_left = PANEL_X + 48 + ((pixel_col - 1) << 5);
					key_width = 30; key_pixel = video_x < key_left + 30;
				end
			end else if(video_y >= panel_y + 41 && video_y < panel_y + 55) begin
				pixel_row = 2; key_top = panel_y + 41;
				if(video_x >= PANEL_X + 8 && video_x < PANEL_X + 54) begin
					pixel_col = 0; key_left = PANEL_X + 8; key_width = 46; key_pixel = 1;
				end else if(video_x >= PANEL_X + 56 && video_x < PANEL_X + 406) begin
					pixel_col = 1 + ((video_x - PANEL_X - 56) >> 5);
					key_left = PANEL_X + 56 + ((pixel_col - 1) << 5);
					key_width = 30; key_pixel = video_x < key_left + 30;
				end else if(video_x >= PANEL_X + 408 && video_x < PANEL_X + 438) begin
					pixel_col = 12; key_left = PANEL_X + 408; key_width = 30; key_pixel = 1;
				end else if(video_x >= PANEL_X + 504 && video_x < PANEL_X + 544) begin
					pixel_col = 13; key_left = PANEL_X + 504; key_width = 40; key_pixel = 1;
				end
			end else if(video_y >= panel_y + 58 && video_y < panel_y + 72) begin
				pixel_row = 3; key_top = panel_y + 58;
				if(video_x >= PANEL_X + 8 && video_x < PANEL_X + 30) begin
					pixel_col = 0; key_left = PANEL_X + 8; key_width = 22; key_pixel = 1;
				end else if(video_x >= PANEL_X + 32 && video_x < PANEL_X + 382) begin
					pixel_col = 1 + ((video_x - PANEL_X - 32) >> 5);
					key_left = PANEL_X + 32 + ((pixel_col - 1) << 5);
					key_width = 30; key_pixel = video_x < key_left + 30;
				end else if(video_x >= PANEL_X + 384 && video_x < PANEL_X + 470) begin
					pixel_col = 12; key_left = PANEL_X + 384; key_width = 86; key_pixel = 1;
				end
			end else if(video_y >= panel_y + 75 && video_y < panel_y + 89) begin
				pixel_row = 4; key_top = panel_y + 75;
				on_light_pixel = video_x >= PANEL_X + 58 && video_x < PANEL_X + 80;
				on_light_lit_pixel = video_x >= PANEL_X + 64 && video_x < PANEL_X + 74 &&
					video_y >= key_top + 4 && video_y < key_top + 10;
				if(video_x >= PANEL_X + 8 && video_x < PANEL_X + 56) begin
					pixel_col=0; key_left=PANEL_X+8; key_width=48; key_pixel=1;
				end else if(video_x >= PANEL_X + 82 && video_x < PANEL_X + 112) begin
					pixel_col=1; key_left=PANEL_X+82; key_width=30; key_pixel=1;
				end else if(video_x >= PANEL_X + 114 && video_x < PANEL_X + 304) begin
					pixel_col=2; key_left=PANEL_X+114; key_width=190; key_pixel=1;
				end else if(video_x >= PANEL_X + 306 && video_x < PANEL_X + 336) begin
					pixel_col=3; key_left=PANEL_X+306; key_width=30; key_pixel=1;
				end else if(video_x >= PANEL_X + 338 && video_x < PANEL_X + 369) begin
					pixel_col=4; key_left=PANEL_X+338; key_width=31; key_pixel=1;
				end else if(video_x >= PANEL_X + 371 && video_x < PANEL_X + 402) begin
					pixel_col=5; key_left=PANEL_X+371; key_width=31; key_pixel=1;
				end else if(video_x >= PANEL_X + 404 && video_x < PANEL_X + 435) begin
					pixel_col=6; key_left=PANEL_X+404; key_width=31; key_pixel=1;
				end else if(video_x >= PANEL_X + 437 && video_x < PANEL_X + 470) begin
					pixel_col=7; key_left=PANEL_X+437; key_width=33; key_pixel=1;
				end else if(video_x >= PANEL_X + 504 && video_x < PANEL_X + 544) begin
					pixel_col=8; key_left=PANEL_X+504; key_width=40; key_pixel=1;
				end
			end
			selected_pixel = pixel_row == selected_row && pixel_col == selected_col;
			latched_pixel = (pixel_row == 2 && pixel_col == 0 && control_latched) ||
				(pixel_row == 3 && (pixel_col == 0 || pixel_col == 12) && shift_latched) ||
				(pixel_row == 4 && pixel_col == 0 && caps_latched) ||
				(pixel_row == 4 && pixel_col == 1 && open_apple) ||
				(pixel_row == 4 && pixel_col == 3 && closed_apple) ||
				(pixel_row == 4 && pixel_col == 8 && transparency > 1);
		end

		if(key_pixel) begin
			if(!commands_page && has_symbol_pair(pixel_row, pixel_col)) begin
				if(video_y < key_top + 6 ||
					((video_y == key_top + 6 || video_y == key_top + 7) && video_x < key_left + 16)) begin
					glyph_y = video_y - key_top;
					requested_character = shown_character(pixel_row, pixel_col, 1, caps_latched);
					glyph_inactive = !shift_latched;
					if(video_x >= key_left + 4 && video_x < key_left + 12 && glyph_y < 8) begin
						glyph_column = video_x - key_left - 4;
						label_pixel = 1;
					end
				end else begin
					glyph_y = video_y - key_top - 6;
					requested_character = shown_character(pixel_row, pixel_col, 0, caps_latched);
					glyph_inactive = shift_latched;
					if(video_x >= key_left + 18 && video_x < key_left + 26 && glyph_y < 8) begin
						glyph_column = video_x - key_left - 18;
						label_pixel = 1;
					end
				end
				if(requested_character != 0) begin
					font_character = requested_character[6:0];
					font_row = glyph_y[2:0];
					font_lowercase = requested_character >= 8'h60;
					if(label_pixel) glyph_pixel = font_data[glyph_column];
				end
			end else begin
				text_length = label_length(pixel_row, pixel_col, commands_page);
				if(!commands_page && pixel_row == 1 && pixel_col == 13) begin
					text_left = key_left + ((key_width - (text_length << 3)) >> 1);
					if(video_y >= key_top + 3 && video_y < key_top + 11) begin
						glyph_y = video_y - key_top - 3;
						if(video_x >= text_left && video_x < text_left + 8) begin
							glyph_column = video_x - text_left;
							label_pixel = 1;
						end
					end
				end else if(!commands_page && pixel_row == 3 && pixel_col == 0) begin
					text_left = key_left + ((key_width - (text_length << 2)) >> 1);
					if(video_y >= key_top + 3 && video_y < key_top + 11) begin
						glyph_y = video_y - key_top - 3;
						if(video_x < text_left) text_slot = 0;
						else begin
							text_slot = (video_x - text_left + 1) >> 2;
							if(text_slot >= text_length) text_slot = text_length - 1;
						end
						if(video_x >= text_left && video_x < text_left + (text_length << 2)) begin
							glyph_column = ((video_x - text_left) & 3) << 1;
							label_pixel = 1;
						end
					end
				end else begin
					text_left = key_left + ((key_width - (text_length << 3)) >> 1);
					if(video_y >= key_top + ((key_height - 8) >> 1) &&
						video_y < key_top + ((key_height - 8) >> 1) + 8) begin
						glyph_y = video_y - key_top - ((key_height - 8) >> 1);
						if(video_x < text_left) text_slot = 0;
						else begin
							text_slot = (video_x - text_left + 1) >> 3;
							if(text_slot >= text_length) text_slot = text_length - 1;
						end
						if(video_x >= text_left && video_x < text_left + (text_length << 3)) begin
							glyph_column = (video_x - text_left) & 7;
							label_pixel = 1;
						end
					end
				end
				if(text_length != 0 && glyph_y >= 0 && glyph_y < 8) begin
					requested_character = label_character(pixel_row, pixel_col, text_slot, commands_page);
					font_character = requested_character[6:0];
					font_row = glyph_y[2:0];
					font_lowercase = requested_character >= 8'h60;
					font_alternate = !commands_page &&
						((pixel_row == 1 && (pixel_col == 0 || pixel_col == 13)) ||
						 (pixel_row == 2 && pixel_col == 13) ||
						 (pixel_row == 4 && ((pixel_col >= 1 && pixel_col <= 7) && pixel_col != 2)));
					if(!commands_page && pixel_row == 4 && pixel_col == 8 && label_pixel)
						glyph_pixel = diamond_pixel(glyph_column, glyph_y);
					else if(label_pixel)
						glyph_pixel = font_alternate ? !font_data[glyph_column] : font_data[glyph_column];
				end
			end
		end
	end

	rgb_out = rgb_in;
	if(panel_pixel) begin
		rgb_out = blend_color(rgb_in, border_pixel ? BORDER_COLOR : PANEL_COLOR, transparency);
		if(well_pixel)
			rgb_out = blend_color(rgb_in, separator_pixel ? LINE_COLOR : WELL_COLOR, transparency);
		if(on_light_pixel) rgb_out = blend_color(rgb_in, ON_HOUSING_COLOR, transparency);
		if(on_light_lit_pixel) rgb_out = blend_color(rgb_in, ON_LIGHT_COLOR, transparency);
		if(key_pixel) begin
			if(selected_pixel)
				rgb_out = blend_color(rgb_in, SELECT_COLOR, transparency);
			else if(latched_pixel)
				rgb_out = blend_color(rgb_in, LATCH_COLOR, transparency);
			else
				rgb_out = blend_color(rgb_in, KEY_COLOR, transparency);
		end
		if(glyph_pixel)
			rgb_out = blend_color(rgb_in, glyph_inactive ? INACTIVE_TEXT_COLOR : TEXT_COLOR, transparency);
	end
end

endmodule