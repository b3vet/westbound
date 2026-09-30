extends RefCounted
# lint: sim
## Network client code follows the server's authority: WB105 skips src/net/.


func smooth(yaw: float) -> float:
	return cos(yaw)
