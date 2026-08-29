`timescale 1ns/1ps

module overlay_equivalence_tb;
	reg clk = 0;
	reg reset = 0;
	reg active = 1;
	reg commands_page = 0;
	reg [2:0] selected_row = 0;
	reg [3:0] selected_col = 0;
	reg shift_latched = 0;
	reg control_latched = 0;
	reg caps_latched = 0;
	reg open_apple = 0;
	reg closed_apple = 0;
	reg [1:0] transparency = 0;
	reg overlay_top = 0;
	reg pixel_clock_double = 1;
	reg hblank = 0;
	reg vblank = 0;
	reg [23:0] rgb_in = 0;

	wire ref_font_alternate;
	wire ref_font_lowercase;
	wire [6:0] ref_font_character;
	wire [2:0] ref_font_row;
	wire [23:0] ref_rgb_out;
	wire candidate_font_alternate;
	wire candidate_font_lowercase;
	wire [6:0] candidate_font_character;
	wire [2:0] candidate_font_row;
	wire [23:0] candidate_rgb_out;
	wire [7:0] ref_font_data = {ref_font_character[3:0], ref_font_row,
		ref_font_alternate ^ ref_font_lowercase};
	wire [7:0] candidate_font_data = {candidate_font_character[3:0], candidate_font_row,
		candidate_font_alternate ^ candidate_font_lowercase};

	integer checks = 0;
	integer frames = 0;
	integer badge_checks = 0;

	always #5 clk = ~clk;

	virtual_keyboard_overlay_reference reference (
		.clk(clk), .reset(reset), .active(active), .commands_page(commands_page),
		.selected_row(selected_row), .selected_col(selected_col),
		.shift_latched(shift_latched), .control_latched(control_latched),
		.caps_latched(caps_latched), .open_apple(open_apple),
		.closed_apple(closed_apple), .transparency(transparency),
		.overlay_top(overlay_top), .hblank(hblank), .vblank(vblank),
		.rgb_in(rgb_in), .font_alternate(ref_font_alternate),
		.font_lowercase(ref_font_lowercase), .font_character(ref_font_character),
		.font_row(ref_font_row), .font_data(ref_font_data), .rgb_out(ref_rgb_out)
	);

	virtual_keyboard_overlay_candidate candidate (
		.clk(clk), .reset(reset), .active(active), .commands_page(commands_page),
		.selected_row(selected_row), .selected_col(selected_col),
		.shift_latched(shift_latched), .control_latched(control_latched),
		.caps_latched(caps_latched), .open_apple(open_apple),
		.closed_apple(closed_apple), .transparency(transparency),
		.overlay_top(overlay_top), .pixel_clock_double(pixel_clock_double),
		.hblank(hblank), .vblank(vblank),
		.rgb_in(rgb_in), .font_alternate(candidate_font_alternate),
		.font_lowercase(candidate_font_lowercase),
		.font_character(candidate_font_character), .font_row(candidate_font_row),
		.font_data(candidate_font_data), .rgb_out(candidate_rgb_out)
	);

	task automatic tick_and_compare(input integer x, input integer y);
		begin
			rgb_in = {x[7:0] ^ y[7:0], x[7:0], y[7:0]};
			@(posedge clk);
			#1;
			if({candidate_font_alternate, candidate_font_lowercase,
				candidate_font_character, candidate_font_row} !==
			   {ref_font_alternate, ref_font_lowercase,
				ref_font_character, ref_font_row})
				$fatal(1, "font request mismatch frame=%0d x=%0d y=%0d ref=%03x candidate=%03x",
					frames, x, y,
					{ref_font_alternate, ref_font_lowercase, ref_font_character, ref_font_row},
					{candidate_font_alternate, candidate_font_lowercase,
						candidate_font_character, candidate_font_row});
			if(active && !hblank && !vblank &&
				candidate.video_x >= 503 && candidate.video_x < 543 &&
				candidate.video_y >= candidate.panel_y + 71 &&
				candidate.video_y < candidate.panel_y + 91) begin
				if(candidate.badge_x !== ((candidate.video_x - 503) >> 1) ||
					candidate.badge_y !== candidate.video_y - candidate.panel_y - 71)
					$fatal(1, "badge coordinate mismatch video=%0d,%0d badge=%0d,%0d",
						candidate.video_x, candidate.video_y, candidate.badge_x, candidate.badge_y);
				if(((candidate.badge_x == 0 || candidate.badge_x == 19) &&
					(candidate.badge_y == 0 || candidate.badge_y == 19)) == candidate.badge_pixel)
					$fatal(1, "badge corner shape mismatch x=%0d y=%0d pixel=%0d",
						candidate.badge_x, candidate.badge_y, candidate.badge_pixel);
				badge_checks = badge_checks + 1;
			end else if(candidate_rgb_out !== ref_rgb_out)
				$fatal(1, "pixel mismatch frame=%0d x=%0d y=%0d ref=%06x candidate=%06x",
					frames, x, y, ref_rgb_out, candidate_rgb_out);
			checks = checks + 1;
		end
	endtask

	task automatic run_normal_frame;
		integer x;
		integer y;
		reg [23:0] pair_rgb;
		reg [21:0] pair_font_request;
		reg [9:0] pair_source_x;
		reg [9:0] pair_video_x;
		reg [8:0] pair_video_y;
		begin
			pixel_clock_double = 0;
			reset = 1;
			hblank = 1;
			vblank = 1;
			@(posedge clk);
			@(posedge clk);
			#1;
			reset = 0;
			vblank = 0;
			@(posedge clk);
			#1;
			for(y = 0; y < 192; y = y + 1) begin
				hblank = 0;
				for(x = 0; x < 560; x = x + 2) begin
					rgb_in = {x[7:0] ^ y[7:0], x[7:0], y[7:0]};
					#1;
					pair_rgb = candidate_rgb_out;
					pair_source_x = candidate.source_x;
					pair_video_x = candidate.video_x;
					pair_video_y = candidate.video_y;
					pair_font_request = {candidate_font_alternate,
						candidate_font_lowercase, candidate_font_character,
						candidate_font_row, candidate_font_data};
					@(posedge clk);
					#1;
					if(candidate_rgb_out !== pair_rgb)
						$fatal(1, "normal-mode pixel pair mismatch x=%0d y=%0d first_pos=%0d,%0d source_x=%0d second_pos=%0d,%0d source_x=%0d first=%06x second=%06x",
							x, y, pair_video_x, pair_video_y, pair_source_x,
							candidate.video_x, candidate.video_y, candidate.source_x,
							pair_rgb, candidate_rgb_out);
					if({candidate_font_alternate, candidate_font_lowercase,
						candidate_font_character, candidate_font_row, candidate_font_data} !== pair_font_request)
						$fatal(1, "normal-mode font pair mismatch x=%0d y=%0d", x, y);
					@(posedge clk);
					#1;
					checks = checks + 2;
				end
				hblank = 1;
				@(posedge clk);
				#1;
			end
			vblank = 1;
			@(posedge clk);
			#1;
			vblank = 0;
			hblank = 0;
			frames = frames + 1;
		end
	endtask

	task automatic run_frame;
		integer x;
		integer y;
		begin
			reset = 1;
			tick_and_compare(-1, -1);
			reset = 0;
			vblank = 0;
			for(y = 0; y < 192; y = y + 1) begin
				hblank = 0;
				for(x = 0; x < 560; x = x + 1)
					tick_and_compare(x, y);
				hblank = 1;
				tick_and_compare(560, y);
			end
			vblank = 1;
			tick_and_compare(-1, 192);
			vblank = 0;
			hblank = 0;
			frames = frames + 1;
		end
	endtask

	initial begin
		integer mode;

		for(mode = 0; mode < 4; mode = mode + 1) begin
			transparency = mode[1:0];
			commands_page = 0;
			overlay_top = mode[0];
			selected_row = mode;
			selected_col = mode * 3;
			shift_latched = mode[0];
			control_latched = mode[1];
			caps_latched = !mode[0];
			open_apple = mode == 1;
			closed_apple = mode == 2;
			run_frame();

			commands_page = 1;
			selected_row = 0;
			selected_col = mode;
			run_frame();
		end

		active = 0;
		run_frame();

		active = 1;
		commands_page = 0;
		transparency = 0;
		run_normal_frame();

		if(badge_checks == 0)
			$fatal(1, "square badge region was not exercised");
		$display("OVERLAY EQUIVALENCE PASS frames=%0d checks=%0d badge_checks=%0d", frames, checks, badge_checks);
		$finish;
	end
endmodule