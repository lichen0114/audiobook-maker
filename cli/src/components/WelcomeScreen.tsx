import React from 'react';
import { Box, Text, useInput } from 'ink';
import Gradient from 'ink-gradient';

interface WelcomeScreenProps {
    onStart: () => void;
}

export function WelcomeScreen({ onStart }: WelcomeScreenProps) {
    useInput((input, key) => {
        if (key.return || input === ' ') {
            onStart();
        }
    });

    return (
        <Box flexDirection="column" paddingX={2}>
            {/* Welcome Message */}
            <Box marginBottom={1}>
                <Text color="cyan" bold>Welcome to Audiobook Maker!</Text>
                <Text> 📚</Text>
            </Box>

            {/* Description */}
            <Box marginBottom={1} flexDirection="column">
                <Box>
                    <Text dimColor>This tool will help you convert your EPUB files into</Text>
                </Box>
                <Box>
                    <Text dimColor>high-quality MP3 audiobooks using </Text>
                    <Text color="magenta" bold>Kokoro TTS</Text>
                    <Text dimColor>.</Text>
                </Box>
            </Box>

            {/* Features Card */}
            <Box
                flexDirection="column"
                borderStyle="round"
                borderColor="gray"
                paddingX={2}
                paddingY={1}
                marginBottom={1}
            >
                <Box marginBottom={1}>
                    <Gradient name="passion">
                        <Text bold>✨ Features</Text>
                    </Gradient>
                </Box>
                <Box flexDirection="column" paddingLeft={1}>
                    <Box>
                        <Text color="cyan">📚  </Text>
                        <Text dimColor>Convert </Text>
                        <Text bold>single or multiple</Text>
                        <Text dimColor> EPUBs at once</Text>
                    </Box>
                    <Box>
                        <Text color="magenta">🎙️   </Text>
                        <Text dimColor>Choose from </Text>
                        <Text bold>11+ different voices</Text>
                    </Box>
                    <Box>
                        <Text color="yellow">⚡  </Text>
                        <Text dimColor>Adjust </Text>
                        <Text bold>speaking speed</Text>
                    </Box>
                    <Box>
                        <Text color="green">📊  </Text>
                        <Text dimColor>Real-time </Text>
                        <Text bold>progress tracking</Text>
                    </Box>
                    <Box>
                        <Text color="blue">🍎  </Text>
                        <Text dimColor>Apple Silicon </Text>
                        <Text bold>GPU acceleration</Text>
                    </Box>
                </Box>
            </Box>

            {/* CTA Button */}
            <Box marginTop={1} borderStyle="round" borderColor="green" paddingX={2} paddingY={1}>
                <Gradient name="mind">
                    <Text bold>Press ENTER or SPACE to start 🚀</Text>
                </Gradient>
            </Box>
        </Box>
    );
}
