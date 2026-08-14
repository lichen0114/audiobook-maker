import React, { useState } from 'react';
import { Box, Text, useInput } from 'ink';
import SelectInput from 'ink-select-input';
import TextInput from 'ink-text-input';
import * as path from 'path';
import type { FileJob, TTSConfig } from '../types/profile.js';
import { useTextEntryFocus } from '../contexts/text-entry.js';
import {
    getDefaultAutoChunkChars,
    getDefaultPytorchChunkChars,
    isAppleSiliconHost,
    isLowMemoryAppleHost,
} from '../utils/apple-host.js';

// Optimal chunk sizes per backend based on benchmarks
// MLX: 900 chars = 180 chars/s (+11% vs 1200)
// PyTorch: 600 chars = 98 chars/s (+3% vs 1200)
const AUTO_CHUNK_CHARS = getDefaultAutoChunkChars();
const IS_APPLE_SILICON = isAppleSiliconHost();
const DEFAULT_RECOVERY_MODE = IS_APPLE_SILICON ? 'apple-balanced' : 'off';
const DEFAULT_WORKERS = 1;
const LOW_MEMORY_APPLE = isLowMemoryAppleHost();

const BACKEND_CHUNK_CHARS: Record<'auto' | 'pytorch' | 'mlx' | 'mock', number> = {
    auto: AUTO_CHUNK_CHARS,
    mlx: 900,
    pytorch: getDefaultPytorchChunkChars(),
    mock: 600,
};

interface ConfigPanelProps {
    files: FileJob[];
    config: TTSConfig;
    onConfirm: (config: TTSConfig) => void;
    onBack: () => void;
}

const accents = [
    { label: '🇺🇸 American English', value: 'a' },
    { label: '🇬🇧 British English', value: 'b' },
];

const allVoices = [
    // American voices
    { label: '💜 af_heart (Female - Warm)', value: 'af_heart', accent: 'a' },
    { label: '💙 af_bella (Female - Confident)', value: 'af_bella', accent: 'a' },
    { label: '💚 af_nicole (Female - Friendly)', value: 'af_nicole', accent: 'a' },
    { label: '🧡 af_sarah (Female - Professional)', value: 'af_sarah', accent: 'a' },
    { label: '💛 af_sky (Female - Energetic)', value: 'af_sky', accent: 'a' },
    { label: '🤍 am_adam (Male - Calm)', value: 'am_adam', accent: 'a' },
    { label: '🩵 am_michael (Male - Authoritative)', value: 'am_michael', accent: 'a' },
    // British voices
    { label: '🩷 bf_emma (Female - Elegant)', value: 'bf_emma', accent: 'b' },
    { label: '💜 bf_isabella (Female - Sophisticated)', value: 'bf_isabella', accent: 'b' },
    { label: '🩶 bm_george (Male - Classic)', value: 'bm_george', accent: 'b' },
    { label: '🤎 bm_lewis (Male - Modern)', value: 'bm_lewis', accent: 'b' },
];

// Legacy export for backward compatibility
const voices = allVoices;

const speeds = [
    { label: '🐢 0.75x - Slow', value: '0.75' },
    { label: '⏸️  0.9x - Relaxed', value: '0.9' },
    { label: '▶️  1.0x - Normal', value: '1.0' },
    { label: '⏩ 1.1x - Slightly Fast', value: '1.1' },
    { label: '🐇 1.25x - Fast', value: '1.25' },
    { label: '🚀 1.5x - Very Fast', value: '1.5' },
];

const backends = [
    { label: IS_APPLE_SILICON ? '🧠 Auto (Adaptive Apple Silicon)' : '🧠 Auto (recommended)', value: 'auto' },
    { label: '🔥 PyTorch/MPS (Stable)', value: 'pytorch' },
    { label: '⚡ MLX (Faster - Experimental)', value: 'mlx' },
];

const formats = [
    { label: '🎵 MP3 (Standard)', value: 'mp3' },
    { label: '📖 M4B (With Chapters)', value: 'm4b' },
];

const bitrates = [
    { label: '📻 128k (Smaller file)', value: '128k' },
    { label: '🎧 192k (Balanced)', value: '192k' },
    { label: '🎼 320k (High quality)', value: '320k' },
];

type ConfigStep = 'accent' | 'voice' | 'speed' | 'backend' | 'format' | 'quality' | 'checkpoint' | 'gpu' | 'output' | 'output_custom' | 'confirm';

export function ConfigPanel({ files, config, onConfirm, onBack }: ConfigPanelProps) {
    const [step, setStep] = useState<ConfigStep>('accent');
    const [selectedAccent, setSelectedAccent] = useState<'a' | 'b'>(config.langCode as 'a' | 'b' || 'a');
    const [selectedVoice, setSelectedVoice] = useState(config.voice);
    const [selectedSpeed, setSelectedSpeed] = useState(config.speed);
    const [selectedBackend, setSelectedBackend] = useState<'auto' | 'pytorch' | 'mlx' | 'mock'>(config.backend || 'auto');
    const [selectedFormat, setSelectedFormat] = useState<'mp3' | 'm4b'>(config.outputFormat || 'mp3');
    const [selectedChunkChars, setSelectedChunkChars] = useState(config.chunkChars || BACKEND_CHUNK_CHARS[config.backend || 'auto']);
    const [useMPS, setUseMPS] = useState(config.useMPS);
    const [checkpointEnabled, setCheckpointEnabled] = useState(config.checkpointEnabled || false);
    const [outputDir, setOutputDir] = useState<string | null>(config.outputDir);
    const [customPath, setCustomPath] = useState('');
    const [selectedBitrate, setSelectedBitrate] = useState<'128k' | '192k' | '320k'>(config.bitrate || '192k');
    const [normalize, setNormalize] = useState(config.normalize || false);
    const [history, setHistory] = useState<ConfigStep[]>([]);
    const [editingFromConfirm, setEditingFromConfirm] = useState(false);

    // Filter voices based on selected accent
    const filteredVoices = allVoices.filter(v => v.accent === selectedAccent);
    const gpuStepApplies = IS_APPLE_SILICON && selectedBackend !== 'mlx';

    useTextEntryFocus(step === 'output_custom');

    const goTo = (next: ConfigStep) => {
        setHistory((prev) => [...prev, step]);
        setStep(next);
    };

    // Editing a single setting from the confirm screen returns there instead of
    // walking the user through every remaining step again.
    const advance = (next: ConfigStep) => {
        if (editingFromConfirm) {
            setEditingFromConfirm(false);
            setHistory([]);
            setStep('confirm');
            return;
        }
        goTo(next);
    };

    const goBack = () => {
        if (history.length === 0) {
            onBack();
            return;
        }
        setStep(history[history.length - 1]);
        setHistory(history.slice(0, -1));
        setEditingFromConfirm(false);
    };

    useInput((input, key) => {
        if (key.escape || (step === 'accent' && key.backspace)) {
            goBack();
        }
    }, { isActive: step !== 'output_custom' });

    const handleAccentSelect = (item: { value: string }) => {
        const accent = item.value as 'a' | 'b';
        setSelectedAccent(accent);
        // Reset voice to first voice of selected accent
        const firstVoice = allVoices.find(v => v.accent === accent);
        if (firstVoice) {
            setSelectedVoice(firstVoice.value);
        }
        advance('voice');
    };

    const handleVoiceSelect = (item: { value: string }) => {
        setSelectedVoice(item.value);
        advance('speed');
    };

    const handleSpeedSelect = (item: { value: string }) => {
        setSelectedSpeed(parseFloat(item.value));
        advance('backend');
    };

    const handleBackendSelect = (item: { value: string }) => {
        const backend = item.value as 'auto' | 'pytorch' | 'mlx' | 'mock';
        setSelectedBackend(backend);
        // Update chunk size to optimal value for selected backend
        setSelectedChunkChars(BACKEND_CHUNK_CHARS[backend]);
        // MLX natively uses Apple Silicon
        if (backend === 'mlx') {
            setUseMPS(true); // MLX always uses Apple Silicon
        }
        advance('format');
    };

    const handleFormatSelect = (item: { value: string }) => {
        const format = item.value as 'mp3' | 'm4b';
        setSelectedFormat(format);
        advance('quality');
    };

    const handleQualitySelect = (item: { value: string }) => {
        // Normalization is a toggle: it must not consume the bitrate choice.
        if (item.value === 'normalize') {
            setNormalize((enabled) => !enabled);
            return;
        }
        if (item.value !== 'continue') {
            setSelectedBitrate(item.value as '128k' | '192k' | '320k');
        }
        advance('checkpoint');
    };

    const handleCheckpointSelect = (item: { value: string }) => {
        const enabled = item.value === 'on';
        setCheckpointEnabled(enabled);
        // MPS only exists on Apple Silicon, and MLX always uses it.
        advance(gpuStepApplies ? 'gpu' : 'output');
    };

    const handleGPUSelect = (item: { value: string }) => {
        setUseMPS(item.value === 'on');
        advance('output');
    };

    const handleOutputSelect = (item: { value: string }) => {
        if (item.value === 'same') {
            setOutputDir(null);
            advance('confirm');
        } else if (item.value === 'custom') {
            goTo('output_custom');
        }
    };

    const handleCustomPathSubmit = (value: string) => {
        if (value.trim()) {
            const resolvedPath = path.resolve(process.cwd(), value.trim());
            setOutputDir(resolvedPath);
            advance('confirm');
        }
    };

    const handleConfirm = (item: { value: string }) => {
        if (item.value !== 'start') {
            setEditingFromConfirm(true);
            goTo(item.value as ConfigStep);
            return;
        }

        onConfirm({
            ...config,
            voice: selectedVoice,
            speed: selectedSpeed,
            langCode: selectedAccent,
            backend: selectedBackend,
            outputFormat: selectedFormat,
            chunkChars: selectedChunkChars,
            workers: DEFAULT_WORKERS,
            useMPS,
            outputDir,
            bitrate: selectedBitrate,
            normalize,
            checkpointEnabled,
            pipelineMode: config.pipelineMode || 'auto',
            recoveryMode: config.recoveryMode || DEFAULT_RECOVERY_MODE,
        });
    };

    const getVoiceLabel = (value: string) =>
        voices.find(v => v.value === value)?.label || value;

    const getAccentLabel = (value: string) =>
        accents.find(a => a.value === value)?.label || value;

    const getSpeedLabel = (value: number) =>
        speeds.find(s => parseFloat(s.value) === value)?.label || `${value}x`;

    const getBackendLabel = (value: string) =>
        backends.find(b => b.value === value)?.label || value;

    const getFormatLabel = (value: string) =>
        formats.find(f => f.value === value)?.label || value;

    const getBitrateLabel = (value: string) =>
        bitrates.find(b => b.value === value)?.label || value;

    const getOutputLabel = () => {
        if (!outputDir) return 'Same as input file';
        return outputDir;
    };

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
                        🌐 Accent: <Text color={step === 'accent' ? 'yellow' : 'green'}>{getAccentLabel(selectedAccent)}</Text>
                    </Text>
                    <Text>
                        🎙️  Voice: <Text color={step === 'voice' ? 'yellow' : 'green'}>{getVoiceLabel(selectedVoice)}</Text>
                    </Text>
                    <Text>
                        ⚡ Speed: <Text color={step === 'speed' ? 'yellow' : 'green'}>{getSpeedLabel(selectedSpeed)}</Text>
                    </Text>
                    <Text>
                        🧠 Backend: <Text color={step === 'backend' ? 'yellow' : 'green'}>{getBackendLabel(selectedBackend)}</Text>
                    </Text>
                    <Text>
                        💾 Format: <Text color={step === 'format' ? 'yellow' : 'green'}>{getFormatLabel(selectedFormat)}</Text>
                    </Text>
                    <Text>
                        🎚️  Quality: <Text color={step === 'quality' ? 'yellow' : 'green'}>{getBitrateLabel(selectedBitrate)}{normalize ? ' + Normalized' : ''}</Text>
                    </Text>
                    <Text>
                        📦 Batch mode: <Text color="green">One file at a time</Text>
                    </Text>
                    {LOW_MEMORY_APPLE && (
                        <Text>
                            🍎 Memory profile: <Text color="yellow">8 GB Apple safety mode</Text>
                        </Text>
                    )}
                    <Text>
                        💾 Checkpointing: <Text color={step === 'checkpoint' ? 'yellow' : checkpointEnabled ? 'green' : 'gray'}>{checkpointEnabled ? 'Enabled' : 'Disabled'}</Text>
                    </Text>
                    {IS_APPLE_SILICON && (
                        <Text>
                            🍎 GPU (Apple Silicon): <Text color={step === 'gpu' ? 'yellow' : useMPS ? 'green' : 'gray'}>{useMPS ? 'Enabled ⚡' : 'Disabled'}</Text>
                        </Text>
                    )}
                    <Text>
                        📁 Output: <Text color={step === 'output' || step === 'output_custom' ? 'yellow' : 'green'}>{getOutputLabel()}</Text>
                    </Text>
                </Box>
            </Box>

            {/* Accent Selection */}
            {step === 'accent' && (
                <Box flexDirection="column">
                    <Text color="yellow" bold>Select accent:</Text>
                    <Text dimColor>Choose English accent for the narration</Text>
                    <Box marginTop={1}>
                        <SelectInput
                            items={accents}
                            onSelect={handleAccentSelect}
                            initialIndex={accents.findIndex(a => a.value === selectedAccent)}
                        />
                    </Box>
                </Box>
            )}

            {/* Voice Selection */}
            {step === 'voice' && (
                <Box flexDirection="column">
                    <Text color="yellow" bold>Select a voice:</Text>
                    <Text dimColor>{selectedAccent === 'a' ? 'American' : 'British'} voices</Text>
                    <Box marginTop={1}>
                        <SelectInput items={filteredVoices} onSelect={handleVoiceSelect} />
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

            {/* Backend Selection */}
            {step === 'backend' && (
                <Box flexDirection="column">
                    <Text color="yellow" bold>Select TTS backend:</Text>
                    <Text dimColor>
                        {LOW_MEMORY_APPLE
                            ? 'Auto uses a low-memory Apple profile on 8 GB Macs. Choose MLX only if you want the faster, riskier path.'
                            : 'Auto starts fast on Apple Silicon and falls back to safer settings after a crash'}
                    </Text>
                    <Box marginTop={1}>
                        <SelectInput
                            items={backends}
                            onSelect={handleBackendSelect}
                            initialIndex={backends.findIndex(b => b.value === selectedBackend)}
                        />
                    </Box>
                </Box>
            )}

            {/* Format Selection */}
            {step === 'format' && (
                <Box flexDirection="column">
                    <Text color="yellow" bold>Select output format:</Text>
                    <Text dimColor>M4B includes chapter markers and book metadata</Text>
                    <Box marginTop={1}>
                        <SelectInput
                            items={formats}
                            onSelect={handleFormatSelect}
                            initialIndex={formats.findIndex(f => f.value === selectedFormat)}
                        />
                    </Box>
                </Box>
            )}

            {/* Quality Selection (Bitrate + Normalization) */}
            {step === 'quality' && (
                <Box flexDirection="column">
                    <Text color="yellow" bold>Select audio quality:</Text>
                    <Text dimColor>Higher bitrate = larger file, better quality</Text>
                    <Box marginTop={1}>
                        <SelectInput
                            items={[
                                ...bitrates.map(b => ({
                                    ...b,
                                    label: b.value === selectedBitrate ? `${b.label} ✓` : b.label,
                                })),
                                { label: `🔊 Normalize audio: ${normalize ? 'ON' : 'OFF'} (toggle)`, value: 'normalize' },
                                { label: '→ Continue', value: 'continue' },
                            ]}
                            onSelect={handleQualitySelect}
                            initialIndex={bitrates.findIndex(b => b.value === selectedBitrate)}
                        />
                    </Box>
                    <Box marginTop={1}>
                        <Text dimColor>Normalization adjusts loudness to -14 LUFS (podcast standard)</Text>
                    </Box>
                </Box>
            )}

            {/* Checkpoint Selection */}
            {step === 'checkpoint' && (
                <Box flexDirection="column">
                    <Text color="yellow" bold>Checkpointing (resume support):</Text>
                    <Text dimColor>Off by default for best throughput and lower disk I/O</Text>
                    <Box marginTop={1}>
                        <SelectInput
                            items={[
                                { label: '🚀 Disable checkpointing (default)', value: 'off' },
                                { label: '💾 Enable checkpointing (resumable)', value: 'on' },
                            ]}
                            onSelect={handleCheckpointSelect}
                            initialIndex={checkpointEnabled ? 1 : 0}
                        />
                    </Box>
                </Box>
            )}

            {/* GPU Acceleration Selection */}
            {step === 'gpu' && (
                <Box flexDirection="column">
                    <Text color="yellow" bold>Apple Silicon GPU Acceleration (MPS):</Text>
                    <Text dimColor>
                        {LOW_MEMORY_APPLE
                            ? 'Disabled by default on 8 GB Macs for stability. Enable it only if you want to override the CPU-safe profile.'
                            : 'Enable for speed on M1/M2/M3 Macs. Disable it if batches become unstable.'}
                    </Text>
                    <Box marginTop={1}>
                        <SelectInput
                            items={[
                                { label: '⚡ Enable GPU Acceleration', value: 'on' },
                                { label: '💤 Disable (Use CPU)', value: 'off' },
                            ]}
                            onSelect={handleGPUSelect}
                            initialIndex={useMPS ? 0 : 1}
                        />
                    </Box>
                </Box>
            )}

            {/* Output Directory Selection */}
            {step === 'output' && (
                <Box flexDirection="column">
                    <Text color="yellow" bold>Where to save output files?</Text>
                    <Box marginTop={1}>
                        <SelectInput
                            items={[
                                { label: '📂 Same folder as input file', value: 'same' },
                                { label: '📁 Custom directory...', value: 'custom' },
                            ]}
                            onSelect={handleOutputSelect}
                        />
                    </Box>
                </Box>
            )}

            {/* Custom Output Path Input */}
            {step === 'output_custom' && (
                <Box flexDirection="column">
                    <Text color="yellow" bold>Enter output directory path:</Text>
                    <Text dimColor>Relative or absolute path. Directory will be created if needed.</Text>
                    <Box marginTop={1}>
                        <Text color="green" bold>{'❯ '}</Text>
                        <TextInput
                            value={customPath}
                            onChange={setCustomPath}
                            onSubmit={handleCustomPathSubmit}
                            placeholder="./output or /path/to/audiobooks"
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
                                { label: '🌐 Change Accent', value: 'accent' },
                                { label: '🎙️  Change Voice', value: 'voice' },
                                { label: '⚡ Change Speed', value: 'speed' },
                                { label: '🧠 Change Backend', value: 'backend' },
                                { label: '💾 Change Format', value: 'format' },
                                { label: '🎚️  Change Quality', value: 'quality' },
                                { label: '💾 Toggle Checkpointing', value: 'checkpoint' },
                                ...(gpuStepApplies ? [{ label: '🍎 Toggle GPU Acceleration', value: 'gpu' }] : []),
                                { label: '📁 Change Output Directory', value: 'output' },
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
