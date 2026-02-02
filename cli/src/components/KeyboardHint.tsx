import React from 'react';
import { Box, Text } from 'ink';

interface KeyHint {
    key: string;
    action: string;
}

interface KeyboardHintProps {
    hints: KeyHint[];
    compact?: boolean;
}

export function KeyboardHint({ hints, compact = true }: KeyboardHintProps) {
    if (compact) {
        return (
            <Box>
                {hints.map((hint, idx) => (
                    <React.Fragment key={hint.key}>
                        <Text color="yellow" bold>{hint.key}</Text>
                        <Text dimColor>:{hint.action}</Text>
                        {idx < hints.length - 1 && <Text dimColor>  </Text>}
                    </React.Fragment>
                ))}
            </Box>
        );
    }

    return (
        <Box flexDirection="column">
            {hints.map((hint) => (
                <Box key={hint.key}>
                    <Text color="yellow" bold>{hint.key.padEnd(8)}</Text>
                    <Text dimColor>→ {hint.action}</Text>
                </Box>
            ))}
        </Box>
    );
}

// Common hint presets
export const PROCESSING_HINTS: KeyHint[] = [
    { key: 'q', action: 'quit' },
];

export const DONE_HINTS: KeyHint[] = [
    { key: 'o', action: 'open folder' },
    { key: 'n', action: 'new batch' },
    { key: 'q', action: 'quit' },
];

export const CONFIG_HINTS: KeyHint[] = [
    { key: 'Enter', action: 'confirm' },
    { key: 'Esc', action: 'back' },
    { key: 'q', action: 'quit' },
];

export const FILE_SELECT_HINTS: KeyHint[] = [
    { key: '↑↓', action: 'navigate' },
    { key: 'Space', action: 'select' },
    { key: 'Enter', action: 'confirm' },
    { key: 'q', action: 'quit' },
];
