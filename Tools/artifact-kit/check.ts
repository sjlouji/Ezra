// Runs inside Ezra itself, before a page is shown: does the model's file compile, and what does it import?
import { transform } from "sucrase";

export function check(source: string): { error?: string; imports: string[] } {
  try {
    const { code } = transform(source, { transforms: ["typescript", "jsx", "imports"], jsxRuntime: "automatic", production: true });
    const imports = Array.from(code.matchAll(/require\(['"]([^'"]+)['"]\)/g), (match) => match[1]);
    // The compiler writes "exports. default =" with a space.
    const hasDefault = /exports\.\s*default\s*=/.test(code) || /exports\.\s*\w+\s*=/.test(code);
    return hasDefault ? { imports } : { error: "The file must export a React component as its default export.", imports };
  } catch (error) {
    return { error: error instanceof Error ? error.message : String(error), imports: [] };
  }
}
