byte Input    @ IB0;
byte Output   @ QB0;

//-----------------------------------------------//
// Box feeder
//-----------------------------------------------//
bit  BoxReady         @ I0.3;
bit  BoxesConveyer    @ Q0.1;
bit  box_feeder_flushing;
bit  box_feeder_ready;

byte box_feeder_state = 0;
void box_feeder() {
	switch(box_feeder_state) {
		case 0: // Reset
			box_feeder_flushing = false;
			box_feeder_ready = false;
			box_feeder_state = 1;
		break;
			
		case 1: // Load
			BoxesConveyer = true;
			if(BoxReady) {
				box_feeder_state = 2;
				box_feeder_ready = true;
			}
		break;
		
		case 2: // Wait flush
			if(box_feeder_flushing) {
				box_feeder_state = 3;
			}
		break;
		
		case 3: // Flush
			BoxesConveyer = true;
			if(BoxReady:f) {
				box_feeder_state = 1;
				box_feeder_flushing = false;
			}
		break;
	}
}

void box_feeder_flush() {
	box_feeder_ready = false;
	box_feeder_flushing = true;
}

//-----------------------------------------------//
// Piece feeder
//-----------------------------------------------//
bit  PieceTypeL          @ I0.0;
bit  PieceTypeH          @ I0.1;
bit  PieceReady          @ I0.2;
bit  PiecesConveyer      @ Q0.0;
byte piece_feeder_target;
bit  piece_feeder_ready;

byte piece_feeder_state = 0;
void piece_feeder() {
	switch(piece_feeder_state) {
		case 0: // Reset
			piece_feeder_target = 0;
			piece_feeder_ready = false;
			piece_feeder_state = 1;
		break;
	
		case 1: // Lookup
			if(!piece_feeder_target) break;
			PiecesConveyer = 1;
			//if((Input & 0x3) == piece_feeder_target) {
			if(Input & 0x3) {
				piece_feeder_state = 2;
			}
		break;
		
		case 2: // -> Sensor2
			PiecesConveyer = 1;
			if(PieceReady) {
				piece_feeder_ready  = true;
				piece_feeder_target = 0;
				piece_feeder_state  = 1;
			}
		break;
	}
}

void piece_feeder_request(byte target) {
	piece_feeder_ready = false;
	piece_feeder_target = target;
}

//-----------------------------------------------//
// Picker
//-----------------------------------------------//
bit  PickerAtZero @ I0.4;
bit  PickerMoving @ I0.5;
bit  PickerTop    @ I0.6;
bit  PickerBottom @ I0.7;
bit  PickerGrip   @ I1.0;

bit  PickerDown   @ Q0.2;
bit  PickerUp     @ Q0.3;
bit  PickerLeft   @ Q0.4;
bit  PickerRight  @ Q0.5;
bit  PickerPick   @ Q0.6;
bit  PickerMagnet @ Q0.7;

bit  picker_done;
bit  picker_ready;
byte picker_x_offset;
byte picker_y_offset;
bit  picker_right_memento;
bit  picker_down_memento;

byte picker_state = 0;
void picker() {
	switch(picker_state) {
		case 0: // Reset
			picker_done = false;
			picker_state = 1;
		break;
		
		case 1: // Move to top-left
			PickerUp = true;
			PickerLeft = true;
			if(PickerMoving) {
				picker_state = 2;
			}
		break;
		
		case 2: // Wait end of movement
			if(PickerMoving:f) {
				if(PickerAtZero) {
					picker_state = 3;
				} else {
					picker_state = 1;
				}
			}
		break;
		
		case 3: // Wait orders from picker_place()
			picker_ready = true;
		break;
		
		case 4: // Pick piece
			PickerPick = true;
			if(PickerBottom) {
				picker_state = 5;
			}
		break;
		
		case 5: // Magnet
			PickerPick = true;
			PickerMagnet = true;
			if(PickerGrip) {
				picker_state = 6;
			}
		break;
		
		case 6: // Up
			PickerMagnet = true;
			if(PickerTop) {
				picker_state = 9;
			}
		break;
		
		case 8: // Wait end of movement
			PickerMagnet = true;
			if(PickerMoving:f) {
				if(picker_x_offset || picker_y_offset) {
					picker_state = 9;
				} else {
					picker_state = 11;
				}
			}
		break;
		
		case 9: // Move to offset
			PickerMagnet = true;
			
			if(picker_x_offset) {
				--picker_x_offset;
				picker_right_memento = true;
			} else {
				picker_right_memento = false;
			}
			
			if(picker_y_offset) {
				--picker_y_offset;
				picker_down_memento = true;
			} else {
				picker_down_memento = false;
			}
			
			picker_state = 10;
		break;
		
		case 10: // Wait movement start
			PickerMagnet = true;
			PickerRight = picker_right_memento;
			PickerDown = picker_down_memento;
			if(PickerMoving) {
				picker_state = 8;
			}
		break;
		
		case 11: // Place
			PickerPick = true;
			PickerMagnet = true;
			if(PickerBottom) {
				picker_done = true;
				picker_state = 1;
			}
		break;
	}
}

void picker_place(byte offset) {
	if(picker_state != 3) return;
	
	picker_x_offset = (offset % 3) + 1;
	picker_y_offset = offset / 3;
	picker_ready = false;
	picker_done = false;
	picker_state = 4;
}

//-----------------------------------------------//
// Main
//-----------------------------------------------//
bit  Start      @ I1.4;
bit  Stop       @ I1.5;
bit  Reset      @ I1.6;
bit  PowerLED   @ Q1.0;

byte box_offset;
byte box_pattern[9];

byte main_state = 0;
void main() {
	static bit running = false;
	
	if(Start) running = true;
	if(!Stop || Reset) running = false;
	
	if(Reset) {
		box_feeder_state = 0;
		piece_feeder_state = 0;
		picker_state = 0;
		main_state = 0;
	}
	
	Output = 0;
	PowerLED = running;
	
	if(!running) return;
	
	box_feeder();
	piece_feeder();
	picker();
	
	switch(main_state) {
		case 0: // Reset
			box_pattern[0] = 1; box_pattern[1] = 2; box_pattern[2] = 1;
			box_pattern[3] = 2; box_pattern[4] = 3; box_pattern[5] = 2;
			box_pattern[6] = 1; box_pattern[7] = 2; box_pattern[8] = 1;
			box_offset = 0;
			main_state = 1;
		break;
		
		case 1: // Request first piece
			piece_feeder_request(box_pattern[0]);
			main_state = 2;
		break;
		
		case 2: // Wait piece, then pick
			if(piece_feeder_ready && box_feeder_ready && picker_ready) {
				picker_place(box_offset);
				main_state = 3;
			}
		break;
		
		case 3: // Request
			if(PickerTop:r) {
				if(++box_offset > 8) {
					// Box full
					box_offset = 0;
				}
				
				piece_feeder_request(box_pattern[box_offset]);
				main_state = 4;
			}
		break;
		
		case 4: // Wait on picker, then next
			if(picker_done) {
				if(!box_offset) {
					// First piece means box is full
					box_feeder_flush();
				}
				
				main_state = 2;
			}
		break;
	}
}