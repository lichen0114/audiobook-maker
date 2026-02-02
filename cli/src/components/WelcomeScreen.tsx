import React from 'react';
import { Box, Text, useInput } from 'ink';

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
            <Box marginBottom={1}>
                <Text color="cyan">Welcome to Audiobook Maker! 📚</Text>
            </Box>

            <Box marginBottom={1} flexDirection="column">
                <Text>This tool will help you convert your EPUB files into</Text>
                <Text>high-quality MP3 audiobooks using Kokoro TTS.</Text>
            </Box>

            <Box marginBottom={1} flexDirection="column">
                <Text color="yellow">✨ Features:</Text>
                <Text>  • Convert single or multiple EPUBs at once</Text>
                <Text>  • Choose from different voices</Text>
                <Text>  • Adjust speaking speed</Text>
                <Text>  • Real-time progress tracking</Text>
            </Box>

            <Box marginTop={1} borderStyle="round" borderColor="green" paddingX={2} paddingY={1}>
                <Text color="green" bold>Press ENTER or SPACE to start 🚀</Text>
            </Box>
        </Box>
    );
}
