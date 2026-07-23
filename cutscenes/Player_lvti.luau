--!strict
-- 由 Anima 插件生成。

local cutscene = {
	name = "Player_lvti",
	duration = 3,
	fps = 30,
	takeCameraControl = true,
	tracks = {
		{
			kind = "animation",
			target = "Player",
			name = "开门动作",
			clips = {
				{ animationId = "rbxassetid://70767390449088", startAt = 0, endAt = 2.5, fadeTime = 0.1, speed = 1, looped = false },
			},
		},
		{
			kind = "event",
			target = "12312",
			name = "事件",
			events = {
				{ t = 0.566667, name = "cutscene_start" },
				{ t = 3, name = "boss_reveal" },
				{ t = 3, name = "cutscene_end" },
			},
		},
		{
			kind = "camera",
			target = "VCam16",
			name = "相机轨道",
			followBinding = "Rig1",
			keyframes = {
				{ t = 0.00270005, value = CFrame.new(29.0164, 1.67574, -148.491, -0.27874, -0.376816, 0.883354, -7.45058e-09, 0.919809, 0.392367, -0.960367, 0.109368, -0.256388), easing = "cubicInOut", outTangent = Vector3.new(0.0712016, -0.203203, 0.894723) },
				{ t = 0.4, value = CFrame.new(29.4436, 0.456522, -143.122, 0.149794, -0.180213, 0.972155, 0, 0.983249, 0.18227, -0.988717, -0.0273029, 0.147285), easing = "cubicInOut", outTangent = Vector3.new(0.0580997, -0.100201, 0.227747), inTangent = Vector3.new(0.0580997, -0.100201, 0.227747) },
				{ t = 0.566667, value = CFrame.new(29.365, 1.07454, -147.124, -0.149279, -0.364034, 0.919345, 0, 0.929763, 0.368159, -0.988795, 0.0549586, -0.138794), easing = "cubicInOut", outTangent = Vector3.new(-0.0786574, 0.194279, -0.928492), inTangent = Vector3.new(-0.0786574, 0.194279, -0.928492) },
				{ t = 0.766667, value = CFrame.new(28.9716, 1.6222, -148.693, -0.17683, -0.433041, 0.883859, -7.45058e-09, 0.89801, 0.439974, -0.984241, 0.0778006, -0.158795), easing = "cubicInOut", outTangent = Vector3.new(-0.160188, 0.0745063, -0.591925), inTangent = Vector3.new(-0.160188, 0.0745063, -0.591925) },
				{ t = 0.9, value = CFrame.new(28.4038, 1.52158, -150.676, -0.278743, -0.381442, 0.881366, 0, 0.91774, 0.397184, -0.960366, 0.110712, -0.255814), easing = "cubicInOut", inTangent = Vector3.new(-0.0946323, -0.0167704, -0.330409) },
			},
		},
		{
			kind = "effect",
			target = "驴踢",
			name = "特效轨道",
			effectCues = {
				{ t = 0.866667, emitMode = "forge" },
			},
		},
		{
			kind = "camera",
			target = "VCam16",
			name = "相机轨道",
			segments = {
				{ from = 0, to = 3 },
			},
			followBinding = "Player",
			keyframes = {
				{ t = 0.0236375, value = CFrame.new(4.35626, 1.08737, -1.46855, -0.285497, -0.23356, 0.929484, 7.45058e-09, 0.96985, 0.243703, -0.95838, 0.0695765, -0.276889), easing = "cubicInOut" },
				{ t = 0.305429, value = CFrame.new(4.2479, 1.06704, 4.3678, 0.447939, -0.208795, 0.869342, -7.45058e-09, 0.972349, 0.233535, -0.894064, -0.104609, 0.435553), easing = "cubicInOut" },
				{ t = 0.495515, value = CFrame.new(4.86156, 0.293107, 1.39502, 0.115138, -0.124591, 0.985505, 9.31323e-10, 0.992103, 0.125425, -0.99335, -0.0144411, 0.114228), easing = "cubicInOut" },
				{ t = 0.78517, value = CFrame.new(6.56561, 0.649827, -2.39851, 0.259013, -0.121145, 0.958246, 0, 0.992103, 0.125425, -0.965874, -0.0324867, 0.256968), easing = "cubicInOut" },
			},
		},
	},
}

return cutscene
