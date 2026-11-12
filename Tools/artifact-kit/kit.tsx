// The runtime Ezra loads into every React artifact: React, the shadcn/ui components, icons, charts,
// and a compiler that turns the one file the model wrote into something that can run.
import * as React from "react";
import * as ReactDOMClient from "react-dom/client";
import * as ReactDOM from "react-dom";
import * as JSXRuntime from "react/jsx-runtime";
import * as Lucide from "lucide-react";
import * as Recharts from "recharts";
import * as CVA from "class-variance-authority";
import * as Clsx from "clsx";
import * as TailwindMerge from "tailwind-merge";
import * as utils from "@/lib/utils";
import { transform } from "sucrase";
import * as ui0 from "@/components/ui/accordion";
import * as ui1 from "@/components/ui/alert";
import * as ui2 from "@/components/ui/aspect-ratio";
import * as ui3 from "@/components/ui/avatar";
import * as ui4 from "@/components/ui/badge";
import * as ui5 from "@/components/ui/breadcrumb";
import * as ui6 from "@/components/ui/button";
import * as ui7 from "@/components/ui/calendar";
import * as ui8 from "@/components/ui/card";
import * as ui9 from "@/components/ui/carousel";
import * as ui10 from "@/components/ui/checkbox";
import * as ui11 from "@/components/ui/collapsible";
import * as ui12 from "@/components/ui/command";
import * as ui13 from "@/components/ui/context-menu";
import * as ui14 from "@/components/ui/dialog";
import * as ui15 from "@/components/ui/drawer";
import * as ui16 from "@/components/ui/dropdown-menu";
import * as ui17 from "@/components/ui/form";
import * as ui18 from "@/components/ui/hover-card";
import * as ui19 from "@/components/ui/input";
import * as ui20 from "@/components/ui/label";
import * as ui21 from "@/components/ui/menubar";
import * as ui22 from "@/components/ui/navigation-menu";
import * as ui23 from "@/components/ui/popover";
import * as ui24 from "@/components/ui/progress";
import * as ui25 from "@/components/ui/radio-group";
import * as ui26 from "@/components/ui/resizable";
import * as ui27 from "@/components/ui/scroll-area";
import * as ui28 from "@/components/ui/select";
import * as ui29 from "@/components/ui/separator";
import * as ui30 from "@/components/ui/sheet";
import * as ui31 from "@/components/ui/skeleton";
import * as ui32 from "@/components/ui/slider";
import * as ui33 from "@/components/ui/sonner";
import * as ui34 from "@/components/ui/switch";
import * as ui35 from "@/components/ui/table";
import * as ui36 from "@/components/ui/tabs";
import * as ui37 from "@/components/ui/textarea";
import * as ui38 from "@/components/ui/toast";
import * as ui39 from "@/components/ui/toaster";
import * as ui40 from "@/components/ui/toggle";
import * as ui41 from "@/components/ui/toggle-group";
import * as ui42 from "@/components/ui/tooltip";

const modules: Record<string, unknown> = {
  "react": React,
  "react-dom": ReactDOM,
  "react-dom/client": ReactDOMClient,
  "react/jsx-runtime": JSXRuntime,
  "lucide-react": Lucide,
  "recharts": Recharts,
  "class-variance-authority": CVA,
  "clsx": Clsx,
  "tailwind-merge": TailwindMerge,
  "@/lib/utils": utils,
  "@/components/ui/accordion": ui0,
  "@/components/ui/alert": ui1,
  "@/components/ui/aspect-ratio": ui2,
  "@/components/ui/avatar": ui3,
  "@/components/ui/badge": ui4,
  "@/components/ui/breadcrumb": ui5,
  "@/components/ui/button": ui6,
  "@/components/ui/calendar": ui7,
  "@/components/ui/card": ui8,
  "@/components/ui/carousel": ui9,
  "@/components/ui/checkbox": ui10,
  "@/components/ui/collapsible": ui11,
  "@/components/ui/command": ui12,
  "@/components/ui/context-menu": ui13,
  "@/components/ui/dialog": ui14,
  "@/components/ui/drawer": ui15,
  "@/components/ui/dropdown-menu": ui16,
  "@/components/ui/form": ui17,
  "@/components/ui/hover-card": ui18,
  "@/components/ui/input": ui19,
  "@/components/ui/label": ui20,
  "@/components/ui/menubar": ui21,
  "@/components/ui/navigation-menu": ui22,
  "@/components/ui/popover": ui23,
  "@/components/ui/progress": ui24,
  "@/components/ui/radio-group": ui25,
  "@/components/ui/resizable": ui26,
  "@/components/ui/scroll-area": ui27,
  "@/components/ui/select": ui28,
  "@/components/ui/separator": ui29,
  "@/components/ui/sheet": ui30,
  "@/components/ui/skeleton": ui31,
  "@/components/ui/slider": ui32,
  "@/components/ui/sonner": ui33,
  "@/components/ui/switch": ui34,
  "@/components/ui/table": ui35,
  "@/components/ui/tabs": ui36,
  "@/components/ui/textarea": ui37,
  "@/components/ui/toast": ui38,
  "@/components/ui/toaster": ui39,
  "@/components/ui/toggle": ui40,
  "@/components/ui/toggle-group": ui41,
  "@/components/ui/tooltip": ui42,
};

function showError(error: unknown) {
  const box = document.createElement("pre");
  box.id = "ezra-error";
  box.style.cssText = "margin:12px;padding:12px;border-radius:8px;background:#fdecee;color:#b3261e;font:12px ui-monospace,monospace;white-space:pre-wrap";
  box.textContent = "This artifact could not be shown.\n\n" + (error instanceof Error ? error.message : String(error));
  document.body.appendChild(box);
}

class Boundary extends React.Component<{ children: React.ReactNode }, { failed: boolean }> {
  state = { failed: false };
  static getDerivedStateFromError() { return { failed: true }; }
  componentDidCatch(error: unknown) { showError(error); }
  render() { return this.state.failed ? null : this.props.children; }
}

/** Compiles the model's file and mounts its default export. Anything that goes wrong is shown in the page. */
export function run(source: string) {
  try {
    const { code } = transform(source, { transforms: ["typescript", "jsx", "imports"], jsxRuntime: "automatic", production: true });
    const module = { exports: {} as Record<string, unknown> };
    const require = (name: string) => {
      const found = modules[name] ?? modules[name.replace(/\.(tsx?|jsx?)$/, "")];
      if (!found) throw new Error(`"${name}" cannot be imported here.`);
      return found;
    };
    new Function("require", "module", "exports", "React", code)(require, module, module.exports, React);
    const App = (module.exports.default ?? Object.values(module.exports).find((value) => typeof value === "function")) as React.ComponentType | undefined;
    if (!App) throw new Error("The file must export a React component as its default export.");
    ReactDOMClient.createRoot(document.getElementById("root")!).render(<Boundary><App /></Boundary>);
  } catch (error) {
    showError(error);
  }
}

export const available = Object.keys(modules);
