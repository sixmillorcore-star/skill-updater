using System;
using System.Collections.Generic;
using System.Drawing;
using System.Globalization;
using System.Windows.Forms;

namespace CodexSkillUpdater
{
    internal sealed class PrimaryActionButton : Button
    {
        protected override void OnPaint(PaintEventArgs e)
        {
            if (Enabled) { base.OnPaint(e); return; }
            e.Graphics.Clear(BackColor);
            if (FlatAppearance.BorderSize > 0)
                using (Pen border = new Pen(FlatAppearance.BorderColor)) e.Graphics.DrawRectangle(border, 0, 0, Width - 1, Height - 1);
            Rectangle bounds = ClientRectangle; bounds.Inflate(-6, -3);
            TextFormatFlags flags = TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.WordBreak | TextFormatFlags.NoPrefix;
            if (RightToLeft == RightToLeft.Yes) flags |= TextFormatFlags.RightToLeft;
            TextRenderer.DrawText(e.Graphics, Text, Font, bounds, ForeColor, flags);
        }
    }

    internal sealed partial class UpdaterForm
    {
        private sealed class RowDisplay
        {
            internal Dictionary<string, object> Raw;
            internal List<string> Providers;
            internal string Name, Identity, Provider, Current, Status, Search, Details;
            internal Color Color;
        }

        private readonly List<RowDisplay> displayRows = new List<RowDisplay>();
        private readonly Dictionary<Dictionary<string, object>, RowDisplay> rowDisplayLookup = new Dictionary<Dictionary<string, object>, RowDisplay>();
        private readonly Dictionary<string, Font> uiFontCache = new Dictionary<string, Font>();
        private Dictionary<string, object> currentReport;
        private int[] columnMinimums;
        private int presentationDepth;
        private bool reflowPending;
        private bool readyToUpdate;

        private Font CachedUiFont(float points)
        {
            string key = preferences.FontFamily + "\u001f" + locale.Culture.Name + "\u001f" + points.ToString("R", CultureInfo.InvariantCulture);
            Font font;
            if (uiFontCache.TryGetValue(key, out font)) return font;
            font = UiFontCatalog.Create(preferences.FontFamily, points, locale.Culture.Name, true);
            Font existing = appearanceFonts.Find(delegate(Font item) { return item.Name == font.Name && item.Size == font.Size; });
            if (existing != null) { font.Dispose(); font = existing; } else appearanceFonts.Add(font);
            uiFontCache[key] = font;
            return font;
        }

        private void BeginPresentation()
        {
            if (presentationDepth++ == 0 && mainLayout != null) mainLayout.SuspendLayout();
        }

        private void EndPresentation()
        {
            if (--presentationDepth != 0) return;
            if (mainLayout != null) mainLayout.ResumeLayout(false);
            if (reflowPending) { reflowPending = false; ReflowLayout(); }
            if (mainLayout != null) mainLayout.PerformLayout();
            QueueColumnFit();
        }

        private void RebuildDisplayRows()
        {
            displayRows.Clear(); rowDisplayLookup.Clear(); columnMinimums = null; readyToUpdate = false;
            foreach (Dictionary<string, object> row in reportRows)
            {
                RowDisplay view = new RowDisplay(); view.Raw = row; view.Name = Get(row, "name");
                view.Providers = RowProviders(row); view.Identity = RowIdentity(row);
                view.Provider = view.Providers.Count > 1 ? T("value.shared") : view.Providers[0];
                view.Current = locale.DisplayValue(Get(row, "current")); view.Status = locale.Status(Get(row, "status"));
                view.Details = FullDetails(row);
                view.Search = view.Name + " " + String.Join(" ", view.Providers.ToArray()) + " " + Get(row, "scope") + " " + Get(row, "skillPath") + " " + Get(row, "detail") + " " + Get(row, "status") + " " + view.Status + " " + locale.TranslateScope(Get(row, "scope"));
                string state = Get(row, "status").ToLowerInvariant(); bool ready = IsTrue(row, "canUpdate");
                readyToUpdate |= ready;
                if (state.Contains("fail") || state.Contains("error") || state.Contains("ผิดพลาด") || state.Contains("ล้มเหลว") || state.Contains("ตรวจไม่ได้") || state.Contains("ไม่สำเร็จ")) view.Color = failure;
                else if (state.Contains("updated") || state.Contains("อัปเดตแล้ว") || state.Contains("ตรงกับ")) view.Color = success;
                else if (ready || state.Contains("เอง") || state.Contains("ไม่มีต้นทาง")) view.Color = warning;
                else view.Color = muted;
                displayRows.Add(view); rowDisplayLookup[row] = view;
            }
        }

        private int[] ColumnMinimums()
        {
            if (columnMinimums != null) return columnMinimums;
            int[] result = new int[4];
            for (int i = 0; i < 4; i++) result[i] = TextRenderer.MeasureText(skills.Columns[i].Text, columnFont).Width + 18;
            Dictionary<string, int> widths = new Dictionary<string, int>();
            Func<string, int> measure = delegate(string value) { int width; if (!widths.TryGetValue(value, out width)) { width = TextRenderer.MeasureText(value, skills.Font).Width + 18; widths[value] = width; } return width; };
            result[1] = Math.Max(result[1], measure("Claude Code"));
            result[2] = Math.Max(result[2], measure("26.1020.11348"));
            foreach (RowDisplay row in displayRows) { result[1] = Math.Max(result[1], measure(row.Provider)); result[2] = Math.Max(result[2], measure(row.Current)); result[3] = Math.Max(result[3], measure(row.Status)); }
            foreach (string key in new[] { "current", "available", "updated", "failed", "unknown", "manual", "modified", "managed", "runtime", "unsupported", "disabled", "claude", "claudeCli", "source", "catalog", "unchanged" }) result[3] = Math.Max(result[3], measure(T("status." + key)));
            columnMinimums = result;
            return result;
        }

        private void StylePrimaryAction()
        {
            update.BackColor = update.Enabled ? Color.FromArgb(215, 215, 208) : surface;
            update.ForeColor = update.Enabled ? Color.FromArgb(28, 28, 28) : muted;
            update.FlatAppearance.BorderColor = update.Enabled ? update.BackColor : Color.FromArgb(43, 43, 43);
            update.FlatAppearance.BorderSize = update.Enabled ? 0 : 1;
        }
    }
}
