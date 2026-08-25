module virtual_keyboard_controller #(
	parameter integer CONFIRM_CYCLES = 10738635,
	parameter integer RESET_CYCLES = 1024,
	parameter integer BUTTON_HOLD_CYCLES = 65536
) (
	input  wire        clk,
	input  wire        reset,
	input  wire [10:0] ps2_key,
	input  wire [6:0]  joystick,
	input  wire        enabled,
	output reg  [10:0] filtered_ps2_key = 0,
	output reg         active = 0,
	output reg         commands_page = 0,
	output reg  [2:0]  selected_row = 1,
	output reg  [3:0]  selected_col = 1,
	output reg         shift_latched = 0,
	output reg         control_latched = 0,
	output reg         caps_latched = 1,
	output wire        shift_active,
	output wire        control_active,
	output reg         open_apple = 0,
	output reg         closed_apple = 0,
	output reg         transparency_cycle = 0,
	output reg         overlay_top = 0,
	output reg         virtual_event = 0,
	output reg         virtual_pressed = 0,
	output reg  [6:0]  virtual_code = 0,
	output reg         command_reset = 0
);

localparam [7:0] SC_F10   = 8'h09;
localparam [7:0] SC_ESC   = 8'h76;
localparam [7:0] SC_ENTER = 8'h5A;
localparam [7:0] SC_UP    = 8'h75;
localparam [7:0] SC_DOWN  = 8'h72;
localparam [7:0] SC_LEFT  = 8'h6B;
localparam [7:0] SC_RIGHT = 8'h74;
localparam [7:0] SC_PAGE_UP = 8'h7D;
localparam [7:0] SC_PAGE_DOWN = 8'h7A;
localparam [7:0] SC_LEFT_SHIFT = 8'h12;
localparam [7:0] SC_RIGHT_SHIFT = 8'h59;
localparam [7:0] SC_CTRL = 8'h14;
localparam [7:0] SC_CAPS = 8'h58;

localparam [2:0] CMD_NONE = 0;
localparam [2:0] CMD_WARM = 1;
localparam [2:0] CMD_COLD = 2;
localparam [2:0] CMD_TEST = 3;

localparam integer CONFIRM_BITS = $clog2(CONFIRM_CYCLES + 1);
localparam integer RESET_BITS = $clog2(RESET_CYCLES + 1);
localparam integer HOLD_BITS = $clog2(BUTTON_HOLD_CYCLES + 1);
localparam [RESET_BITS-1:0] RESET_COUNT_VALUE = RESET_CYCLES[RESET_BITS-1:0];
localparam [HOLD_BITS-1:0] HOLD_COUNT_VALUE = BUTTON_HOLD_CYCLES[HOLD_BITS-1:0];

reg raw_toggle = 0;
reg enter_down = 0;
reg virtual_key_down = 0;
reg [CONFIRM_BITS-1:0] confirm_counter = 0;
reg [RESET_BITS-1:0] reset_counter = 0;
reg [HOLD_BITS-1:0] hold_counter = 0;
reg [2:0] command = CMD_NONE;
reg [6:0] joystick_d = 0;
reg physical_left_shift = 0;
reg physical_right_shift = 0;
reg physical_control = 0;

wire new_event = ps2_key[10] != raw_toggle;
wire [6:0] joystick_pressed = joystick & ~joystick_d;
wire joystick_fire_released = !joystick[4] && joystick_d[4];
wire key_down = ps2_key[9];
wire extended = ps2_key[8];
wire [7:0] scan_code = ps2_key[7:0];

assign shift_active = shift_latched | physical_left_shift | physical_right_shift;
assign control_active = control_latched | physical_control;

function automatic [3:0] row_last_col(input [2:0] row);
	case(row)
		0: row_last_col = 14;
		1: row_last_col = 13;
		2: row_last_col = 13;
		3: row_last_col = 12;
		default: row_last_col = 8;
	endcase
endfunction

function automatic [7:0] normal_code(input [2:0] row, input [3:0] col);
	begin
		normal_code = 0;
		case(row)
			0: case(col)
				0: normal_code = 7'h1B;
				1: normal_code = "1"; 2: normal_code = "2";
				3: normal_code = "3"; 4: normal_code = "4";
				5: normal_code = "5"; 6: normal_code = "6";
				7: normal_code = "7"; 8: normal_code = "8";
				9: normal_code = "9"; 10: normal_code = "0";
				11: normal_code = "-"; 12: normal_code = "=";
				13: normal_code = 7'h7F;
				default: normal_code = 0;
			endcase
			1: case(col)
				0: normal_code = 7'h09;
				1: normal_code = "Q"; 2: normal_code = "W";
				3: normal_code = "E"; 4: normal_code = "R";
				5: normal_code = "T"; 6: normal_code = "Y";
				7: normal_code = "U"; 8: normal_code = "I";
				9: normal_code = "O"; 10: normal_code = "P";
				11: normal_code = "["; 12: normal_code = "]";
				13: normal_code = 7'h0D;
			endcase
			2: case(col)
				1: normal_code = "A"; 2: normal_code = "S";
				3: normal_code = "D"; 4: normal_code = "F";
				5: normal_code = "G"; 6: normal_code = "H";
				7: normal_code = "J"; 8: normal_code = "K";
				9: normal_code = "L"; 10: normal_code = ";";
				11: normal_code = "'"; 12: normal_code = 8'h60;
				default: normal_code = 0;
			endcase
			3: case(col)
				1: normal_code = 7'h5C;
				2: normal_code = "Z"; 3: normal_code = "X";
				4: normal_code = "C"; 5: normal_code = "V";
				6: normal_code = "B"; 7: normal_code = "N";
				8: normal_code = "M"; 9: normal_code = ",";
				10: normal_code = "."; 11: normal_code = "/";
				default: normal_code = 0;
			endcase
			4: case(col)
				2: normal_code = 7'h20;
				4: normal_code = 7'h08;
				5: normal_code = 7'h15;
				6: normal_code = 7'h0A;
				7: normal_code = 7'h0B;
				default: normal_code = 0;
			endcase
		endcase
	end
endfunction

function automatic [7:0] shifted_code(input [2:0] row, input [3:0] col);
	begin
		shifted_code = normal_code(row, col);
		if(row == 0) begin
			case(col)
				1: shifted_code = "!"; 2: shifted_code = "@";
				3: shifted_code = "#"; 4: shifted_code = "$";
				5: shifted_code = "%"; 6: shifted_code = "^";
				7: shifted_code = "&"; 8: shifted_code = "*";
				9: shifted_code = "("; 10: shifted_code = ")";
				11: shifted_code = "_"; 12: shifted_code = "+";
			endcase
		end else if(row == 1) begin
			if(col == 11) shifted_code = "{";
			else if(col == 12) shifted_code = "}";
		end else if(row == 2) begin
			if(col == 10) shifted_code = ":";
			else if(col == 11) shifted_code = 7'h22;
			else if(col == 12) shifted_code = "~";
		end else if(row == 3) begin
			if(col == 1) shifted_code = "|";
			else if(col == 9) shifted_code = "<";
			else if(col == 10) shifted_code = ">";
			else if(col == 11) shifted_code = "?";
		end
	end
endfunction

function automatic is_letter(input [7:0] code);
	is_letter = code >= "A" && code <= "Z";
endfunction

task automatic release_virtual_key;
	begin
		if(virtual_key_down) begin
			virtual_pressed <= 0;
			virtual_event <= ~virtual_event;
			virtual_key_down <= 0;
		end
	end
endtask

task automatic close_overlay;
	begin
		release_virtual_key();
		active <= 0;
		commands_page <= 0;
		shift_latched <= 0;
		control_latched <= 0;
		open_apple <= 0;
		closed_apple <= 0;
		enter_down <= 0;
		confirm_counter <= 0;
	end
endtask

task automatic activate_selected_key;
	reg [7:0] code;
	begin
		code = 0;
		if(selected_row == 0 && selected_col == 14) begin
			commands_page <= 1;
			selected_col <= 0;
		end else if(selected_row == 2 && selected_col == 0) begin
			control_latched <= ~control_latched;
		end else if(selected_row == 3 && (selected_col == 0 || selected_col == 12)) begin
			shift_latched <= ~shift_latched;
		end else if(selected_row == 4 && selected_col == 0) begin
			caps_latched <= ~caps_latched;
		end else if(selected_row == 4 && selected_col == 1) begin
			open_apple <= ~open_apple;
		end else if(selected_row == 4 && selected_col == 3) begin
			closed_apple <= ~closed_apple;
		end else if(selected_row == 4 && selected_col == 8) begin
			transparency_cycle <= 1;
		end else begin
			code = normal_code(selected_row, selected_col);
			if(is_letter(code)) begin
				if(!(shift_active ^ caps_latched)) code = code + 7'h20;
			end else if(shift_active) begin
				code = shifted_code(selected_row, selected_col);
			end
			if(control_active && code >= 8'h40) code = code & 8'h1F;
			if(code != 0) begin
				virtual_code <= code[6:0];
				virtual_pressed <= 1;
				virtual_event <= ~virtual_event;
				virtual_key_down <= 1;
			end
		end
	end
endtask

always @(posedge clk) begin
	command_reset <= 0;
	transparency_cycle <= 0;

	if(reset) begin
		raw_toggle <= ps2_key[10];
		filtered_ps2_key <= 0;
		active <= 0;
		commands_page <= 0;
		selected_row <= 1;
		selected_col <= 1;
		shift_latched <= 0;
		control_latched <= 0;
		caps_latched <= 1;
		open_apple <= 0;
		closed_apple <= 0;
		overlay_top <= 0;
		virtual_event <= 0;
		virtual_pressed <= 0;
		virtual_code <= 0;
		virtual_key_down <= 0;
		enter_down <= 0;
		confirm_counter <= 0;
		reset_counter <= 0;
		hold_counter <= 0;
		command <= CMD_NONE;
		joystick_d <= joystick;
		physical_left_shift <= 0;
		physical_right_shift <= 0;
		physical_control <= 0;
	end else begin
		joystick_d <= joystick;
		if(new_event) begin
			raw_toggle <= ps2_key[10];
			if(!extended && scan_code == SC_LEFT_SHIFT)
				physical_left_shift <= key_down;
			else if(!extended && scan_code == SC_RIGHT_SHIFT)
				physical_right_shift <= key_down;
			else if(scan_code == SC_CTRL)
				physical_control <= key_down;
			else if(!key_down && !extended && scan_code == SC_CAPS)
				caps_latched <= ~caps_latched;
		end
		if(command != CMD_NONE) begin
			if(reset_counter != 0) begin
				command_reset <= 1;
				reset_counter <= reset_counter - 1'd1;
			end else if(hold_counter != 0) begin
				hold_counter <= hold_counter - 1'd1;
			end else begin
				command <= CMD_NONE;
				close_overlay();
			end
		end else if(!enabled && active) begin
			close_overlay();
		end else if(enabled && joystick_pressed[6]) begin
			if(active) close_overlay();
			else begin
				active <= 1;
				commands_page <= 0;
				selected_row <= 1;
				selected_col <= 1;
				shift_latched <= 0;
				control_latched <= 0;
				open_apple <= 0;
				closed_apple <= 0;
			end
		end else if(active && commands_page && joystick_pressed[1] && selected_col != 0) begin
			selected_col <= selected_col - 1'd1;
		end else if(active && commands_page && joystick_pressed[0] && selected_col != 3) begin
			selected_col <= selected_col + 1'd1;
		end else if(active && !commands_page && joystick_pressed[1] && selected_col != 0) begin
			selected_col <= selected_col - 1'd1;
		end else if(active && !commands_page && joystick_pressed[0] && selected_col < row_last_col(selected_row)) begin
			selected_col <= selected_col + 1'd1;
		end else if(active && !commands_page && selected_row == 2 && selected_col == 13 && joystick_pressed[3]) begin
			overlay_top <= 1;
		end else if(active && !commands_page && selected_row == 2 && selected_col == 13 && joystick_pressed[2]) begin
			overlay_top <= 0;
		end else if(active && !commands_page && joystick_pressed[3] && selected_row != 0) begin
			selected_row <= selected_row - 1'd1;
			if(selected_col > row_last_col(selected_row - 1'd1)) selected_col <= row_last_col(selected_row - 1'd1);
		end else if(active && !commands_page && joystick_pressed[2] && selected_row != 4) begin
			selected_row <= selected_row + 1'd1;
			if(selected_col > row_last_col(selected_row + 1'd1)) selected_col <= row_last_col(selected_row + 1'd1);
		end else if(active && joystick_pressed[4]) begin
			enter_down <= 1;
			confirm_counter <= 0;
			if(commands_page) begin
				if(selected_col == 0) begin
					commands_page <= 0;
					selected_row <= 0;
					selected_col <= 14;
				end
			end else begin
				activate_selected_key();
			end
		end else if(active && joystick_fire_released) begin
			enter_down <= 0;
			confirm_counter <= 0;
			release_virtual_key();
		end else if(new_event) begin
			if(!active) begin
				if(enabled && key_down && !extended && scan_code == SC_F10) begin
					active <= 1;
					commands_page <= 0;
					selected_row <= 1;
					selected_col <= 1;
					shift_latched <= 0;
					control_latched <= 0;
					open_apple <= 0;
					closed_apple <= 0;
				end else begin
					filtered_ps2_key[10] <= ~filtered_ps2_key[10];
					filtered_ps2_key[9:0] <= ps2_key[9:0];
				end
			end else if(key_down && !extended && (scan_code == SC_F10 || scan_code == SC_ESC)) begin
				close_overlay();
			end else if(key_down && extended && scan_code == SC_PAGE_UP) begin
				overlay_top <= 1;
			end else if(key_down && extended && scan_code == SC_PAGE_DOWN) begin
				overlay_top <= 0;
			end else if(commands_page) begin
				if(key_down && extended && scan_code == SC_LEFT && selected_col != 0)
					selected_col <= selected_col - 1'd1;
				else if(key_down && extended && scan_code == SC_RIGHT && selected_col != 3)
					selected_col <= selected_col + 1'd1;
				else if(key_down && !extended && scan_code == SC_ENTER) begin
					enter_down <= 1;
					confirm_counter <= 0;
					if(selected_col == 0) begin
						commands_page <= 0;
						selected_row <= 0;
						selected_col <= 14;
					end
				end else if(!key_down && !extended && scan_code == SC_ENTER) begin
					enter_down <= 0;
					confirm_counter <= 0;
				end
			end else begin
				if(key_down && extended && scan_code == SC_LEFT && selected_col != 0)
					selected_col <= selected_col - 1'd1;
				else if(key_down && extended && scan_code == SC_RIGHT && selected_col < row_last_col(selected_row))
					selected_col <= selected_col + 1'd1;
				else if(key_down && extended && scan_code == SC_UP && selected_row == 2 && selected_col == 13)
					overlay_top <= 1;
				else if(key_down && extended && scan_code == SC_DOWN && selected_row == 2 && selected_col == 13)
					overlay_top <= 0;
				else if(key_down && extended && scan_code == SC_UP && selected_row != 0) begin
					selected_row <= selected_row - 1'd1;
					if(selected_col > row_last_col(selected_row - 1'd1)) selected_col <= row_last_col(selected_row - 1'd1);
				end else if(key_down && extended && scan_code == SC_DOWN && selected_row != 4) begin
					selected_row <= selected_row + 1'd1;
					if(selected_col > row_last_col(selected_row + 1'd1)) selected_col <= row_last_col(selected_row + 1'd1);
				end else if(key_down && !extended && scan_code == SC_ENTER) begin
					enter_down <= 1;
					activate_selected_key();
				end else if(!key_down && !extended && scan_code == SC_ENTER) begin
					enter_down <= 0;
					release_virtual_key();
				end
			end
		end

		if(commands_page && enter_down && selected_col != 0) begin
			if(confirm_counter == CONFIRM_CYCLES - 1) begin
				command <= selected_col[2:0];
				reset_counter <= RESET_COUNT_VALUE;
				hold_counter <= HOLD_COUNT_VALUE;
				open_apple <= selected_col == CMD_COLD;
				closed_apple <= selected_col == CMD_TEST;
				enter_down <= 0;
			end else begin
				confirm_counter <= confirm_counter + 1'd1;
			end
		end
	end
end

endmodule