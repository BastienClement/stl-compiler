
byte queueLength = 0;

bit data[50] @ M10.0;
byte queue[20] @ MB30;
bit showQueue[10] @ M50.0;
byte queuePositions[10] @ MB60;
bit queueDirections[10] @ M70.0;

bit startPLC @ I1.4;
bit automatic @ I1.3;
bit loadingPoint @ I0.0;
bit EOMElevator @ I0.1;
bit SensForkOut @ I0.2;
bit SensForkMid @ I0.3;
bit SensForkIn @ I0.4;
bit AutoElevatorSensor @ I0.5;
bit packAtLoadingPoint @ I0.6;
bit unloadingPointReady @ I0.7;

byte mainState @ MB100;
byte userTemp @ MB102;
byte userCycle @ MB104;
bit userLoad @ M106.0;
bit startHMI @ M106.1;
bit userLoadCycle @ M106.2;
bit doSync @ M106.3;
byte scanPosition @ MB110;
byte output @ QB0;
bit forkIn @ Q0.7;
bit forkOut @ Q0.6;

void setOutputs(byte wishedPosition){
	output = (wishedPosition & 0x3F) | (output & 0xc0);
}

byte deQueue(){
	byte entry;
	byte queuePos;
	
	if(queueLength < 1)
		return 0;
	
	--queueLength;
	
	entry = queue[0];
	
	queuePos = 0;
	loop: if(queuePos < queueLength) {
		queue[queuePos] = queue[queuePos + 1];
		++queuePos;
		goto loop;
	}
	
	return entry;
}

void enQueue(byte position, bit load){
	if(queueLength >= 20)
		return;
	
	if(load){
		position |= 0x80;
	}
	
	queue[queueLength] = position;
	++queueLength;
}


void doHMI() {
	byte i;
	byte buf;
	
	i = 0;
	showQueueLoop: if(i < 10) {
		showQueue[i] = queueLength > i;
		++i;
		goto showQueueLoop;
	}
	
	i = 0;
	queuePosLoop: if(i < 10) {
		queuePositions[i] = queue[i] & 0x7F;
		++i;
		goto queuePosLoop;
	}
	
	i = 0;
	queueDirectionLoop: if(i < 10) {
		queueDirections[i] = queue[i] & 0x80;
		++i;
		goto queueDirectionLoop;
	}
}

bit AutoElevatorSensorFalling;
bit EOMElevatorRising;

void sync() {
	static byte sync_state;
	static bit  didAutoLift;
	
	if(doSync:r) {
		sync_state = 0;
		scanPosition = 1;
	}

	if(!doSync)
		return;
	
	switch(sync_state) {
		case 0:
			didAutoLift = false;
			if(output != scanPosition)
				sync_state = 1;
			else
				sync_state = 2;
		break;
		
		case 1:
			setOutputs(scanPosition);
			if(EOMElevatorRising) sync_state = 2;
		break;
		
		case 2:
			forkIn = true;
			if(SensForkIn) sync_state = 3;
		break;
		
		case 3:
			if(autoElevatorSensor)
				sync_state = 8;
			if(SensForkMid) sync_state = 4;
		break;
		
		case 8:
			didAutoLift = true;
			forkIn = true;
			if(SensForkIn && AutoElevatorSensorFalling) sync_state = 9;
		break;
		
		case 9:
			if(SensForkMid) sync_state = 4;
		break;
		
		case 4:
			data[scanPosition - 1] = didAutoLift;
			if(didAutoLift)
				sync_state = 5;
			else
				sync_state = 6;
		break;
		
		case 5:
			forkIn = true;
			if(SensForkIn && AutoElevatorSensorFalling) sync_state = 6;
		break;
		
		case 6:
			if(SensForkMid) sync_state = 7;
		break;
		
		case 7:
			++scanPosition;
			if(scanPosition > 50)
				doSync = false;
			else
				sync_state = 0;
		break;
		
		default:
			sync_state = 0;
	}
}

void main() {
	static byte hmiDelay = 0;
	static bit syncing = false;
	
	if(++hmiDelay > 10) {
		doHMI();
		hmiDelay = 0;
	}
	
	output = output & 0x3F;
	
	AutoElevatorSensorFalling = autoElevatorSensor:f;
	EOMElevatorRising = EOMElevator:r;
		
	if(!automatic){ 
		return;
	}
	
	if((userTemp > 0 && userTemp < 51) && (startPLC || startHMI):r){
		enQueue(userTemp, userLoad);
	}
	
	switch (mainState) {
		case 0 :
			sync();
			if(doSync)
				return;
			
			if(userCycle = deQueue()) {
				userLoadCycle = userCycle & 0x80;
				userCycle &= 0x7F;
				
				if(userLoadCycle == data[userCycle - 1])
					return;
					
				if(userLoadCycle) {
					mainState = 2;
				} else {
					if(output == userCycle)
						mainState = 8;
					else
						mainState = 7;
				}
			}
		break;
		
		case 2 :
			setOutputs(51);
			if(EOMElevatorRising) mainState = 3;
		break;
				
		case 3 :
			forkOut = packAtLoadingPoint;
			if(SensForkOut && AutoElevatorSensorFalling) mainState = 4;
		break;
		
		case 4 :
			setOutputs(userCycle);
			if(EOMElevatorRising) mainState = 5;
		break;
		
		case 5 :
			forkIn = true;
			if(SensForkIn && AutoElevatorSensorFalling) {
				mainState = 6;
				data[userCycle - 1] = 1;
			}
		break;
		
		case 6 :
			if(SensForkMid) mainState = 0;
		break;
		
		case 7 :
			setOutputs(userCycle);
			if(EOMElevatorRising) mainState = 8;
		break;
		
		case 8 :
			forkIn = true;
			if(SensForkIn && AutoElevatorSensorFalling) mainState = 9;
		break;
		
		case 9 :
			if(SensForkMid) {
				if(userCycle == 10)
					mainState = 11;
				else
					mainState = 10;
			}
		break;
		
		case 10 :
			setOutputs(10);
			if(EOMElevatorRising) mainState = 11;
		break;
		
		case 11 : 
			forkOut = true;
			if(SensForkOut && AutoElevatorSensorFalling) {
				data[userCycle - 1] = 0;
				mainState = 6;
			}
		break;
		
		default :
			mainState = 0;

	}

	startHMI = false;
}

