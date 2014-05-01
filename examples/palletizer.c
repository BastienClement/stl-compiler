bit ElevatorExitSensor @ I0.0;
bit AdvanceElevatorSensor @ I0.1;
bit MaxBoxSensor @ I0.2;
bit TableInSensor @ I0.3;
bit TableOutSensor @ I0.4;
bit BoxBlocked @ I0.5;
bit ElevatorLowSensor @ I0.6;
bit ElevatorHighSensor @ I0.7;
bit ElevatorHighMidSensor @ I1.0;
bit ElevatorHighLowSensor @ I1.1;
bit PalletDetector @ I1.2;
bit Automatic @ I1.3;
bit Start @ I1.4;
bit Stop @ I1.5;
bit Reset @I1.6;

bit BoxElevator @ Q0.0;
bit PushBox @ Q0.1;
bit HoldBox @ Q0.2;
bit MatAdvance @ Q0.3;
bit BlockBox @ Q0.4;
bit PalletsElevatorUp @ Q0.5;
bit PalletsElevatorDown @ Q0.6;
bit ConveyPallets @ Q0.7;
bit PowerLED @ Q1.0;
bit StopLED @ Q1.3;
bit ResetLED @ Q1.1;
byte Output @ QB0;

int feederState = 0;
int waitingBoxes = 0;
int pushedBoxed = 0;
int liftState = 0;
int layersAmount = 0;

void doFeeder(){
	if(MaxBoxSensor:r) ++waitingBoxes;
	if(pushedBoxed > 1) return;
	
	switch(feederState) {
		case 0 : 
			BoxElevator = 1;
			if(ElevatorExitSensor) feederState = 1;
		break;
		
		case 1 :
			PushBox = 1;
			if(AdvanceElevatorSensor) {
				feederState = 0; 
				++ pushedBoxed; 
			}	
		break;
		
		default :
			feederState = 0;
	}
	
}

void doLift() {
	switch(liftState) {
		case 0 :
			PalletsElevatorDown = 1;
			if(ElevatorLowSensor) liftState = 1;
		break;
		
		case 1 :
			ConveyPallets = 1;
			if(PalletDetector) liftState = 2;
		break;
		
		case 2 :
			PalletsElevatorUp = 1;
			if(ElevatorHighSensor) liftState = 3;
		break;
		
		case 3 :
			if(waitingBoxes == 2) liftState = 4;
		break;
		
		case 4 :
			HoldBox = 1;
			MatAdvance = 1;
			if(TableOutSensor) liftState = 5;
		break;
		
		case 5 :
			MatAdvance = 1;
			BlockBox = 1;
			if(BoxBlocked) {
				liftState = 6;
				waitingBoxes = 0;
				pushedBoxed = 0;
			}
		break;
		
		case 6 :
			BlockBox = 1;
			if(TableInSensor) {
				liftState = 7;
				++ layersAmount;
			}
		break;
		
		case 7 :
			PalletsElevatorDown = 1;
			switch(layersAmount) {
				case 0 :
				case 1 :
					if(ElevatorHighMidSensor) {
						liftState = 3;
					}					
				break;
				
				case 2 :
					if(ElevatorHighLowSensor) {
						liftState = 3;
					}	
				break;
				
				case 3 :
					if(ElevatorLowSensor) {
						liftState = 8;
						layersAmount = 0;
					}
				break;
							
			}
		break;	
		
		case 8 :
			ConveyPallets = 1;
			if(PalletDetector:f) liftState = 1;
		break;
	}
}


void main(){
	static bit Running = 0;
	if(Start) Running = 1;
	if(Reset || !Stop) Running = 0;
	if(Reset) {
		feederState = 0;
		waitingBoxes = 0;
		pushedBoxed = 0;
		liftState = 0;
		layersAmount = 0;
	}
	
	PowerLED = Running;
	StopLED = !Running;
	ResetLED = Reset;
	Output = 0;
	
	if(!Running) return;

	doFeeder();
	doLift();
}