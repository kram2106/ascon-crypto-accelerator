# ####################################################################

#  Created by Genus(TM) Synthesis Solution 21.14-s082_1 on Fri Mar 20 15:16:35 IST 2026

# ####################################################################

set sdc_version 2.0

set_units -capacitance 1000fF
set_units -time 1000ps

# Set the current design
current_design Ascon

create_clock -name "clk" -period 6.0 -waveform {0.0 5.0} [get_ports clk]
set_clock_transition 0.25 [get_clocks clk]
set_load -pin_load 0.05 [get_ports enc_cipher_textxSO]
set_load -pin_load 0.05 [get_ports enc_tagxSO]
set_load -pin_load 0.05 [get_ports enc_readyxSO]
set_load -pin_load 0.05 [get_ports dec_plain_textxSO]
set_load -pin_load 0.05 [get_ports dec_tagxSO]
set_load -pin_load 0.05 [get_ports dec_readyxSO]
set_clock_gating_check -setup 0.0 
set_input_delay -clock [get_clocks clk] -add_delay -max 0.8 [get_ports rst]
set_input_delay -clock [get_clocks clk] -add_delay -min 0.3 [get_ports rst]
set_input_delay -clock [get_clocks clk] -add_delay -max 0.8 [get_ports keyxSI]
set_input_delay -clock [get_clocks clk] -add_delay -min 0.3 [get_ports keyxSI]
set_input_delay -clock [get_clocks clk] -add_delay -max 0.8 [get_ports noncexSI]
set_input_delay -clock [get_clocks clk] -add_delay -min 0.3 [get_ports noncexSI]
set_input_delay -clock [get_clocks clk] -add_delay -max 0.8 [get_ports associated_dataxSI]
set_input_delay -clock [get_clocks clk] -add_delay -min 0.3 [get_ports associated_dataxSI]
set_input_delay -clock [get_clocks clk] -add_delay -max 0.8 [get_ports plain_textxSI]
set_input_delay -clock [get_clocks clk] -add_delay -min 0.3 [get_ports plain_textxSI]
set_input_delay -clock [get_clocks clk] -add_delay -max 0.8 [get_ports enc_startxSI]
set_input_delay -clock [get_clocks clk] -add_delay -min 0.3 [get_ports enc_startxSI]
set_input_delay -clock [get_clocks clk] -add_delay -max 0.8 [get_ports cipher_textxSI]
set_input_delay -clock [get_clocks clk] -add_delay -min 0.3 [get_ports cipher_textxSI]
set_input_delay -clock [get_clocks clk] -add_delay -max 0.8 [get_ports dec_startxSI]
set_input_delay -clock [get_clocks clk] -add_delay -min 0.3 [get_ports dec_startxSI]
set_output_delay -clock [get_clocks clk] -add_delay -max 2.0 [get_ports enc_cipher_textxSO]
set_output_delay -clock [get_clocks clk] -add_delay -max 2.0 [get_ports enc_tagxSO]
set_output_delay -clock [get_clocks clk] -add_delay -max 2.0 [get_ports enc_readyxSO]
set_output_delay -clock [get_clocks clk] -add_delay -max 2.0 [get_ports dec_plain_textxSO]
set_output_delay -clock [get_clocks clk] -add_delay -max 2.0 [get_ports dec_tagxSO]
set_output_delay -clock [get_clocks clk] -add_delay -max 2.0 [get_ports dec_readyxSO]
set_output_delay -clock [get_clocks clk] -add_delay -min 0.0 [get_ports enc_cipher_textxSO]
set_output_delay -clock [get_clocks clk] -add_delay -min 0.0 [get_ports enc_tagxSO]
set_output_delay -clock [get_clocks clk] -add_delay -min 0.0 [get_ports enc_readyxSO]
set_output_delay -clock [get_clocks clk] -add_delay -min 0.0 [get_ports dec_plain_textxSO]
set_output_delay -clock [get_clocks clk] -add_delay -min 0.0 [get_ports dec_tagxSO]
set_output_delay -clock [get_clocks clk] -add_delay -min 0.0 [get_ports dec_readyxSO]
set_max_fanout 20.000 [current_design]
set_max_transition 0.35 [current_design]
set_wire_load_mode "enclosed"
set_clock_uncertainty -setup 0.15 [get_clocks clk]
set_clock_uncertainty -hold 0.1 [get_clocks clk]
