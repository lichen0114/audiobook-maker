import React, { useState } from 'react';
import { Box, Text, useInput } from 'ink';
import TextInput from 'ink-text-input';
import Gradient from 'ink-gradient';
import { glob } from 'glob';
import * as path from 'path';
import * as fs from 'fs';

interface FileSelectorProps {
    onFilesSelected: (files: string[]) => void;
}

export function FileSelector({ onFilesSelected }: FileSelectorProps) {
    const [input, setInput] = useState('');
    const [files, setFiles] = useState<string[]>([]);
    const [error, setError] = useState<string | null>(null);
    const [mode, setMode] = useState<'input' | 'confirm'>('input');

    const handleSubmit = async (value: string) => {
        setError(null);

        if (!value.trim()) {
            setError('Please enter a file path or glob pattern');
            return;
        }

        try {
            let foundFiles: string[] = [];

            // Check if it's a glob pattern
            if (value.includes('*')) {
                const matches = await glob(value, {
                    absolute: true,
                    nodir: true
                });
                foundFiles = matches.filter(f => f.toLowerCase().endsWith('.epub'));
            } else {
                // Single file or directory
                const absolutePath = path.resolve(process.cwd(), value);

                if (fs.existsSync(absolutePath)) {
                    const stat = fs.statSync(absolutePath);

                    if (stat.isDirectory()) {
                        // Search for EPUBs in directory
                        const matches = await glob(path.join(absolutePath, '**/*.epub'), {
                            absolute: true,
                            nodir: true
                        });
                        foundFiles = matches;
                    } else if (absolutePath.toLowerCase().endsWith('.epub')) {
                        foundFiles = [absolutePath];
                    } else {
                        setError('File must be an EPUB file');
                        return;
                    }
                } else {
                    setError(`File not found: ${value}`);
                    return;
                }
            }

            if (foundFiles.length === 0) {
                setError('No EPUB files found');
                return;
            }

            setFiles(foundFiles);
            setMode('confirm');
        } catch (err) {
            setError(`Error: ${err instanceof Error ? err.message : 'Unknown error'}`);
        }
    };

    useInput((input, key) => {
        if (mode === 'confirm') {
            if (key.return || input === 'y') {
                onFilesSelected(files);
            } else if (input === 'n' || key.escape) {
                setMode('input');
                setFiles([]);
                setInput('');
            }
        }
    });

    if (mode === 'confirm') {
        return (
            <Box flexDirection="column" paddingX={2}>
                {/* Found Files Header */}
                <Box marginBottom={1}>
                    <Text color="green">✔ </Text>
                    <Text bold>Found </Text>
                    <Text color="cyan" bold>{files.length}</Text>
                    <Text bold> EPUB file{files.length !== 1 ? 's' : ''}</Text>
                </Box>

                {/* File List Card */}
                <Box
                    flexDirection="column"
                    borderStyle="round"
                    borderColor="cyan"
                    paddingX={2}
                    paddingY={1}
                    marginBottom={1}
                >
                    {files.slice(0, 10).map((file, index) => (
                        <Box key={index}>
                            <Text dimColor>{String(index + 1).padStart(2, ' ')}. </Text>
                            <Text color="white">{path.basename(file)}</Text>
                        </Box>
                    ))}
                    {files.length > 10 && (
                        <Box marginTop={1}>
                            <Text dimColor>   ... and </Text>
                            <Text color="yellow">{files.length - 10}</Text>
                            <Text dimColor> more</Text>
                        </Box>
                    )}
                </Box>

                {/* Confirm Prompt */}
                <Box borderStyle="round" borderColor="yellow" paddingX={2} paddingY={1}>
                    <Gradient name="morning">
                        <Text bold>Continue with these files? (y/n)</Text>
                    </Gradient>
                </Box>
            </Box>
        );
    }

    return (
        <Box flexDirection="column" paddingX={2}>
            {/* Section Header */}
            <Box marginBottom={1}>
                <Gradient name="fruit">
                    <Text bold>📂 Select EPUB files</Text>
                </Gradient>
            </Box>

            {/* Help Text */}
            <Box
                marginBottom={1}
                flexDirection="column"
                borderStyle="single"
                borderColor="gray"
                paddingX={2}
                paddingY={1}
            >
                <Text dimColor>Enter a file path, directory, or glob pattern:</Text>
                <Box marginTop={1} flexDirection="column" paddingLeft={1}>
                    <Box>
                        <Text color="cyan">• </Text>
                        <Text color="white">./book.epub</Text>
                        <Text dimColor>          (single file)</Text>
                    </Box>
                    <Box>
                        <Text color="cyan">• </Text>
                        <Text color="white">./*.epub</Text>
                        <Text dimColor>            (all in current dir)</Text>
                    </Box>
                    <Box>
                        <Text color="cyan">• </Text>
                        <Text color="white">./books/</Text>
                        <Text dimColor>            (all in folder)</Text>
                    </Box>
                </Box>
            </Box>

            {/* Input */}
            <Box marginBottom={1}>
                <Text color="green" bold>{'❯ '}</Text>
                <TextInput
                    value={input}
                    onChange={setInput}
                    onSubmit={handleSubmit}
                    placeholder="Enter path or pattern..."
                />
            </Box>

            {/* Error Message */}
            {error && (
                <Box>
                    <Text color="red">✘ {error}</Text>
                </Box>
            )}
        </Box>
    );
}
