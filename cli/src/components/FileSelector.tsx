import React, { useState } from 'react';
import { Box, Text, useInput } from 'ink';
import TextInput from 'ink-text-input';
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
                <Box marginBottom={1}>
                    <Text color="green">📚 Found {files.length} EPUB file{files.length !== 1 ? 's' : ''}:</Text>
                </Box>

                <Box flexDirection="column" marginBottom={1} paddingLeft={2}>
                    {files.slice(0, 10).map((file, index) => (
                        <Text key={index} color="cyan">
                            {index + 1}. {path.basename(file)}
                        </Text>
                    ))}
                    {files.length > 10 && (
                        <Text dimColor>... and {files.length - 10} more</Text>
                    )}
                </Box>

                <Box borderStyle="round" borderColor="yellow" paddingX={2} paddingY={1}>
                    <Text color="yellow">Continue with these files? (y/n)</Text>
                </Box>
            </Box>
        );
    }

    return (
        <Box flexDirection="column" paddingX={2}>
            <Box marginBottom={1}>
                <Text color="cyan">📂 Select EPUB files</Text>
            </Box>

            <Box marginBottom={1} flexDirection="column">
                <Text dimColor>Enter a file path, directory, or glob pattern:</Text>
                <Text dimColor>Examples:</Text>
                <Text dimColor>  • ./book.epub</Text>
                <Text dimColor>  • ./*.epub (all EPUBs in current dir)</Text>
                <Text dimColor>  • ./books/ (all EPUBs in folder)</Text>
            </Box>

            <Box marginBottom={1}>
                <Text color="green">{'> '}</Text>
                <TextInput
                    value={input}
                    onChange={setInput}
                    onSubmit={handleSubmit}
                    placeholder="Enter path or pattern..."
                />
            </Box>

            {error && (
                <Box>
                    <Text color="red">❌ {error}</Text>
                </Box>
            )}
        </Box>
    );
}
