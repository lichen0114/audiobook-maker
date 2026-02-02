import React, { useState } from 'react';
import { Box, Text, useInput } from 'ink';
import SelectInput from 'ink-select-input';
import type { TTSConfig, FileJob } from '../App.js';

interface ConfigPanelProps {
    files: FileJob[];
    config: TTSConfig;
    onConfirm: (config: TTSConfig) => void;
    onBack: () => void;
}

const voices = [
    { label: '💜 af_heart (American Female - Warm)', value: 'af_heart' },
    { label: '💙 af_bella (American Female - Confident)', value: 'af_bella' },
    { label: '💚 af_nicole (American Female - Friendly)', value: 'af_nicole' },
    { label: '🧡 af_sarah (American Female - Professional)', value: 'af_sarah' },
    { label: '💛 af_sky (American Female - Energetic)', value: 'af_sky' },
    { label: '🤍 am_adam (American Male - Calm)', value: 'am_adam' },
    { label: '🩵 am_michael (American Male - Authoritative)', value: 'am_michael' },
    { label: '🩷 bf_emma (British Female - Elegant)', value: 'bf_emma' },
    { label: '💜 bf_isabella (British Female - Sophisticated)', value: 'bf_isabella' },
    { label: '🩶 bm_george (British Male - Classic)', value: 'bm_george' },
    { label: '🤎 bm_lewis (British Male - Modern)', value: 'bm_lewis' },
];

const speeds = [
    { label: '🐢 0.75x - Slow', value: '0.75' },
    { label: '⏸️  0.9x - Relaxed', value: '0.9' },
    { label: '▶️  1.0x - Normal', value: '1.0' },
    { label: '⏩ 1.1x - Slightly Fast', value: '1.1' },
    { label: '🐇 1.25x - Fast', value: '1.25' },
    { label: '🚀 1.5x - Very Fast', value: '1.5' },
];

type ConfigStep = 'voice' | 'speed' | 'confirm';

export function ConfigPanel({ files, config, onConfirm, onBack }: ConfigPanelProps) {
    const [step, setStep] = useState<ConfigStep>('voice');
    const [selectedVoice, setSelectedVoice] = useState(config.voice);
    const [selectedSpeed, setSelectedSpeed] = useState(config.speed);

    useInput((input, key) => {
        if (key.escape || (step === 'voice' && key.backspace)) {
            onBack();
        }
    });

    const handleVoiceSelect = (item: { value: string }) => {
        setSelectedVoice(item.value);
        setStep('speed');
    };

    const handleSpeedSelect = (item: { value: string }) => {
        setSelectedSpeed(parseFloat(item.value));
        setStep('confirm');
    };

    const handleConfirm = (item: { value: string }) => {
        if (item.value === 'start') {
            onConfirm({
                ...config,
                voice: selectedVoice,
                speed: selectedSpeed,
            });
        } else if (item.value === 'voice') {
            setStep('voice');
        } else if (item.value === 'speed') {
            setStep('speed');
        }
    };

    const getVoiceLabel = (value: string) =>
        voices.find(v => v.value === value)?.label || value;

    const getSpeedLabel = (value: number) =>
        speeds.find(s => parseFloat(s.value) === value)?.label || `${value}x`;

    return (
        <Box flexDirection="column" paddingX={2}>
            <Box marginBottom={1}>
                <Text color="cyan">⚙️  Configuration</Text>
            </Box>

            {/* Summary Box */}
            <Box
                flexDirection="column"
                borderStyle="round"
                borderColor="gray"
                paddingX={2}
                paddingY={1}
                marginBottom={1}
            >
                <Text color="white" bold>Current Settings:</Text>
                <Box marginTop={1} flexDirection="column">
                    <Text>
                        📚 Files: <Text color="cyan">{files.length}</Text>
                    </Text>
                    <Text>
                        🎙️  Voice: <Text color={step === 'voice' ? 'yellow' : 'green'}>{getVoiceLabel(selectedVoice)}</Text>
                    </Text>
                    <Text>
                        ⚡ Speed: <Text color={step === 'speed' ? 'yellow' : 'green'}>{getSpeedLabel(selectedSpeed)}</Text>
                    </Text>
                </Box>
            </Box>

            {/* Voice Selection */}
            {step === 'voice' && (
                <Box flexDirection="column">
                    <Text color="yellow" bold>Select a voice:</Text>
                    <Box marginTop={1}>
                        <SelectInput items={voices} onSelect={handleVoiceSelect} />
                    </Box>
                </Box>
            )}

            {/* Speed Selection */}
            {step === 'speed' && (
                <Box flexDirection="column">
                    <Text color="yellow" bold>Select reading speed:</Text>
                    <Box marginTop={1}>
                        <SelectInput
                            items={speeds}
                            onSelect={handleSpeedSelect}
                            initialIndex={speeds.findIndex(s => s.value === '1.0')}
                        />
                    </Box>
                </Box>
            )}

            {/* Confirmation */}
            {step === 'confirm' && (
                <Box flexDirection="column">
                    <Text color="green" bold>Ready to process! 🚀</Text>
                    <Box marginTop={1}>
                        <SelectInput
                            items={[
                                { label: '✅ Start Processing', value: 'start' },
                                { label: '🎙️  Change Voice', value: 'voice' },
                                { label: '⚡ Change Speed', value: 'speed' },
                            ]}
                            onSelect={handleConfirm}
                        />
                    </Box>
                </Box>
            )}

            <Box marginTop={1}>
                <Text dimColor>Press ESC to go back</Text>
            </Box>
        </Box>
    );
}
