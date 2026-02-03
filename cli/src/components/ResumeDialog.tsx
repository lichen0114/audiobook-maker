import React from 'react';
import { Box, Text } from 'ink';
import SelectInput from 'ink-select-input';

export interface CheckpointInfo {
    totalChunks: number;
    completedChunks: number;
}

interface ResumeDialogProps {
    checkpoint: CheckpointInfo;
    onResume: () => void;
    onStartFresh: () => void;
}

export function ResumeDialog({ checkpoint, onResume, onStartFresh }: ResumeDialogProps) {
    const progressPercent = Math.round((checkpoint.completedChunks / checkpoint.totalChunks) * 100);

    const handleSelect = (item: { value: string }) => {
        if (item.value === 'resume') {
            onResume();
        } else {
            onStartFresh();
        }
    };

    return (
        <Box flexDirection="column" paddingX={2}>
            <Box marginBottom={1}>
                <Text color="yellow">⚠️  Previous progress found</Text>
            </Box>

            {/* Progress Summary Box */}
            <Box
                flexDirection="column"
                borderStyle="round"
                borderColor="yellow"
                paddingX={2}
                paddingY={1}
                marginBottom={1}
            >
                <Text color="white" bold>Checkpoint Status:</Text>
                <Box marginTop={1} flexDirection="column">
                    <Text>
                        📊 Progress: <Text color="cyan">{checkpoint.completedChunks}</Text>/<Text color="cyan">{checkpoint.totalChunks}</Text> chunks ({progressPercent}%)
                    </Text>
                    <Box marginTop={1}>
                        <Text dimColor>
                            {progressPercent < 100
                                ? 'You can resume from where you left off or start fresh.'
                                : 'Processing was almost complete. Resume to finish.'}
                        </Text>
                    </Box>
                </Box>
            </Box>

            <Box flexDirection="column">
                <Text color="yellow" bold>What would you like to do?</Text>
                <Box marginTop={1}>
                    <SelectInput
                        items={[
                            { label: '▶️  Resume from checkpoint', value: 'resume' },
                            { label: '🔄 Start fresh (delete checkpoint)', value: 'fresh' },
                        ]}
                        onSelect={handleSelect}
                    />
                </Box>
            </Box>
        </Box>
    );
}
