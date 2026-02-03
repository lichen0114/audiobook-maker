import React, { useState } from 'react';
import { Box, Text, useInput } from 'ink';
import SelectInput from 'ink-select-input';
import TextInput from 'ink-text-input';

export interface BookMetadata {
    title: string;
    author: string;
    hasCover: boolean;
    coverPath?: string; // Custom cover path if overridden
}

interface MetadataEditorProps {
    metadata: BookMetadata;
    onConfirm: (metadata: BookMetadata) => void;
    onBack: () => void;
}

type EditorStep = 'review' | 'edit_title' | 'edit_author' | 'edit_cover';

export function MetadataEditor({ metadata, onConfirm, onBack }: MetadataEditorProps) {
    const [step, setStep] = useState<EditorStep>('review');
    const [title, setTitle] = useState(metadata.title);
    const [author, setAuthor] = useState(metadata.author);
    const [coverPath, setCoverPath] = useState(metadata.coverPath || '');
    const [hasCover, setHasCover] = useState(metadata.hasCover);

    useInput((input, key) => {
        if (key.escape) {
            if (step === 'review') {
                onBack();
            } else {
                setStep('review');
            }
        }
    });

    const handleReviewSelect = (item: { value: string }) => {
        switch (item.value) {
            case 'continue':
                onConfirm({
                    title,
                    author,
                    hasCover: hasCover || !!coverPath,
                    coverPath: coverPath || undefined,
                });
                break;
            case 'edit_title':
                setStep('edit_title');
                break;
            case 'edit_author':
                setStep('edit_author');
                break;
            case 'edit_cover':
                setStep('edit_cover');
                break;
        }
    };

    const handleTitleSubmit = (value: string) => {
        if (value.trim()) {
            setTitle(value.trim());
        }
        setStep('review');
    };

    const handleAuthorSubmit = (value: string) => {
        if (value.trim()) {
            setAuthor(value.trim());
        }
        setStep('review');
    };

    const handleCoverSubmit = (value: string) => {
        if (value.trim()) {
            setCoverPath(value.trim());
            setHasCover(true);
        }
        setStep('review');
    };

    return (
        <Box flexDirection="column" paddingX={2}>
            <Box marginBottom={1}>
                <Text color="cyan">📖 M4B Metadata</Text>
            </Box>

            {/* Metadata Summary Box */}
            <Box
                flexDirection="column"
                borderStyle="round"
                borderColor="gray"
                paddingX={2}
                paddingY={1}
                marginBottom={1}
            >
                <Text color="white" bold>Book Information:</Text>
                <Box marginTop={1} flexDirection="column">
                    <Text>
                        📕 Title: <Text color={step === 'edit_title' ? 'yellow' : 'green'}>{title}</Text>
                    </Text>
                    <Text>
                        ✍️  Author: <Text color={step === 'edit_author' ? 'yellow' : 'green'}>{author}</Text>
                    </Text>
                    <Text>
                        🖼️  Cover: <Text color={step === 'edit_cover' ? 'yellow' : hasCover || coverPath ? 'green' : 'gray'}>
                            {coverPath ? `Custom: ${coverPath}` : (hasCover ? 'From EPUB' : 'None')}
                        </Text>
                    </Text>
                </Box>
            </Box>

            {/* Review Step */}
            {step === 'review' && (
                <Box flexDirection="column">
                    <Text color="yellow" bold>Review metadata for your audiobook:</Text>
                    <Text dimColor>This info will be embedded in the M4B file</Text>
                    <Box marginTop={1}>
                        <SelectInput
                            items={[
                                { label: '✅ Continue with this metadata', value: 'continue' },
                                { label: '📕 Edit Title', value: 'edit_title' },
                                { label: '✍️  Edit Author', value: 'edit_author' },
                                { label: '🖼️  Set Custom Cover Image', value: 'edit_cover' },
                            ]}
                            onSelect={handleReviewSelect}
                        />
                    </Box>
                </Box>
            )}

            {/* Edit Title */}
            {step === 'edit_title' && (
                <Box flexDirection="column">
                    <Text color="yellow" bold>Enter book title:</Text>
                    <Box marginTop={1}>
                        <Text color="green" bold>{'❯ '}</Text>
                        <TextInput
                            value={title}
                            onChange={setTitle}
                            onSubmit={handleTitleSubmit}
                            placeholder="Book Title"
                        />
                    </Box>
                    <Box marginTop={1}>
                        <Text dimColor>Press Enter to confirm, ESC to cancel</Text>
                    </Box>
                </Box>
            )}

            {/* Edit Author */}
            {step === 'edit_author' && (
                <Box flexDirection="column">
                    <Text color="yellow" bold>Enter author name:</Text>
                    <Box marginTop={1}>
                        <Text color="green" bold>{'❯ '}</Text>
                        <TextInput
                            value={author}
                            onChange={setAuthor}
                            onSubmit={handleAuthorSubmit}
                            placeholder="Author Name"
                        />
                    </Box>
                    <Box marginTop={1}>
                        <Text dimColor>Press Enter to confirm, ESC to cancel</Text>
                    </Box>
                </Box>
            )}

            {/* Edit Cover */}
            {step === 'edit_cover' && (
                <Box flexDirection="column">
                    <Text color="yellow" bold>Enter path to cover image:</Text>
                    <Text dimColor>Supports JPG, PNG, GIF. Leave empty to use EPUB cover.</Text>
                    <Box marginTop={1}>
                        <Text color="green" bold>{'❯ '}</Text>
                        <TextInput
                            value={coverPath}
                            onChange={setCoverPath}
                            onSubmit={handleCoverSubmit}
                            placeholder="/path/to/cover.jpg"
                        />
                    </Box>
                    <Box marginTop={1}>
                        <Text dimColor>Press Enter to confirm, ESC to cancel</Text>
                    </Box>
                </Box>
            )}

            <Box marginTop={1}>
                <Text dimColor>Press ESC to go back</Text>
            </Box>
        </Box>
    );
}
