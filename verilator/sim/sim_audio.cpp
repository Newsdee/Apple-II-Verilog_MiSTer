#include "sim_audio.h"
#include <iostream>
#include <fstream>
#include <list>
#ifndef _MSC_VER
#include <SDL.h>
#endif
using namespace std;

SimClock clk;
bool outputToFile;
ofstream audioFile;
#ifndef _MSC_VER
SDL_AudioDeviceID audioDevice = 0;
const Uint32 maxQueuedAudioBytes = 44100 * 2 * sizeof(float) / 10;
#endif

SimAudio::SimAudio(int systemClockFrequency, bool saveToFile)
{
	clk = SimClock(systemClockFrequency / 44100);
	outputToFile = saveToFile;
	sample_count = 0;
	peak_level = 0;
	playback_available = false;
}

SimAudio::~SimAudio()
{

}

void SimAudio::Clock(signed short left, signed short right) {
	clk.Tick();
	if (clk.IsRising()) {
		float l = left / 32768.0f;
		float r = right / 32768.0f;
		float absLeft = l < 0 ? -l : l;
		float absRight = r < 0 ? -r : r;
		if (absLeft > peak_level) peak_level = absLeft;
		if (absRight > peak_level) peak_level = absRight;
		sample_count++;
		if (outputToFile) {
			audioFile.write((const char*)&l, sizeof(float));
		}
#ifndef _MSC_VER
		if (audioDevice && SDL_GetQueuedAudioSize(audioDevice) < maxQueuedAudioBytes) {
			float sample[2] = {l, r};
			SDL_QueueAudio(audioDevice, sample, sizeof(sample));
		}
#endif
	}
}

void SimAudio::CollectDebug(signed short left, signed short right) {
	float vol_l = left / 32768.0f;
	float vol_r = right / 32768.0f;
	debug_pos++;
	if (debug_pos == debug_max_samples) { debug_pos = 0; }
	debug_wave_l[debug_pos] = vol_l;
	debug_wave_r[debug_pos] = vol_r;

}

void SimAudio::Initialise() {
	// Reset plot data
	for (int c = 0; c < debug_max_samples; c++) {
		debug_wave_l[c] = 0;
		debug_wave_r[c] = 0;
		debug_positions[c] = (double)c / (double)debug_max_samples;
	}
	if (outputToFile)
	{
		// Setup Audio output stream
		audioFile.open("audio.wav", ios::binary);
	}
#ifndef _MSC_VER
	if (SDL_Init(SDL_INIT_AUDIO) != 0) {
		cerr << "SDL audio initialization failed: " << SDL_GetError() << endl;
		return;
	}

	SDL_AudioSpec desired = {};
	desired.freq = 44100;
	desired.format = AUDIO_F32SYS;
	desired.channels = 2;
	desired.samples = 1024;
	audioDevice = SDL_OpenAudioDevice(NULL, 0, &desired, NULL, 0);
	if (!audioDevice) {
		cerr << "SDL audio device open failed: " << SDL_GetError() << endl;
		return;
	}
	playback_available = true;
	SDL_PauseAudioDevice(audioDevice, 0);
#endif
}
void SimAudio::CleanUp() {
#ifndef _MSC_VER
	if (audioDevice) {
		SDL_CloseAudioDevice(audioDevice);
		audioDevice = 0;
	}
#endif
	if (outputToFile)
	{
		audioFile.close();
	}
}

