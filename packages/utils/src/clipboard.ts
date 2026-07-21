/**
 * Copy text to clipboard with fallback support
 * Copy text to the clipboard, with a fallback for compatibility
 */
export interface CopyResult {
  success: boolean;
  error?: string;
}

/**
 * Copy text to clipboard using modern Clipboard API with fallback
 * @param text - Text to copy
 * @returns Promise<CopyResult>
 */
export async function copyToClipboard(text: string): Promise<CopyResult> {
  // Check if the modern Clipboard API is available
  if (navigator.clipboard && window.isSecureContext) {
    try {
      await navigator.clipboard.writeText(text);
      return { success: true };
    } catch (error) {
      // If modern API fails, try fallback
      console.warn('Modern clipboard API failed, trying fallback:', error);
      return fallbackCopyToClipboard(text);
    }
  }
  
  // Use fallback method for older browsers or non-secure contexts
  return fallbackCopyToClipboard(text);
}

/**
 * Fallback copy method using document.execCommand (deprecated but widely supported)
 * @param text - Text to copy
 * @returns CopyResult
 */
function fallbackCopyToClipboard(text: string): CopyResult {
  try {
    // Create a temporary textarea element
    const textArea = document.createElement('textarea');
    textArea.value = text;
    
    // Make the textarea invisible but not display: none (which would make it uncopyable)
    textArea.style.position = 'fixed';
    textArea.style.left = '-999999px';
    textArea.style.top = '-999999px';
    document.body.appendChild(textArea);
    textArea.focus();
    textArea.select();
    
    try {
      // Execute copy command
      document.execCommand('copy');
      textArea.remove();
      return { success: true };
    } finally {
      // Ensure textarea is removed even if execCommand fails
      textArea.remove();
    }
  } catch (error) {
    return { 
      success: false, 
      error: error instanceof Error ? error.message : 'Unknown error' 
    };
  }
}

/**
 * Copy text to clipboard with message integration
 * Clipboard copy with a message notification
 * @param text - Text to copy
 * @param options - Configuration options
 */
export async function copyWithMessage(
  text: string, 
  options: {
    successMessage?: string;
    errorMessage?: string;
    showMessage?: (message: string, type: 'success' | 'error') => void;
  } = {}
): Promise<CopyResult> {
  const {
    successMessage = 'Copied to clipboard!',
    errorMessage = 'Failed to copy to clipboard',
    showMessage
  } = options;

  const result = await copyToClipboard(text);
  
  if (showMessage) {
    if (result.success) {
      showMessage(successMessage, 'success');
    } else {
      showMessage(`${errorMessage}: ${result.error}`, 'error');
    }
  }
  
  return result;
}

/**
 * Vue Composition API hook for clipboard functionality
 * Clipboard hook for Vue Composition API
 */
export function useClipboard() {
  const copy = async (text: string): Promise<CopyResult> => {
    return await copyToClipboard(text);
  };

  return {
    copy,
    copyWithMessage: (
      text: string,
      options?: Parameters<typeof copyWithMessage>[1]
    ) => copyWithMessage(text, options)
  };
}
