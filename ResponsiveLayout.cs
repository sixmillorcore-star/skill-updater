using System;
using System.Drawing;
using System.Windows.Forms;

namespace CodexSkillUpdater
{
    internal sealed partial class UpdaterForm
    {
        private TableLayoutPanel mainLayout;
        private bool reflowing;
        private bool columnFitQueued;
        private bool fittingColumns;

        private void QueueColumnFit()
        {
            if (columnFitQueued || !IsHandleCreated || IsDisposed || Disposing) return;
            columnFitQueued = true;
            BeginInvoke((MethodInvoker)delegate {
                columnFitQueued = false;
                if (!IsDisposed && !Disposing && skills.Visible) FitColumns();
            });
        }

        private Control Bound(string key)
        {
            Control control; return boundControls.TryGetValue(key, out control) ? control : null;
        }

        private static Size FullText(Control control)
        {
            return TextRenderer.MeasureText(control.Text.Length == 0 ? "Ag" : control.Text, control.Font,
                new Size(32767, 32767), TextFormatFlags.SingleLine | TextFormatFlags.NoPrefix);
        }

        private static int WrapHeight(Control control, int width)
        {
            return TextRenderer.MeasureText(control.Text.Length == 0 ? "Ag" : control.Text, control.Font,
                new Size(Math.Max(1, width), 32767), TextFormatFlags.WordBreak | TextFormatFlags.TextBoxControl | TextFormatFlags.NoPrefix).Height + 2;
        }

        private static void PlaceLabel(Label label, int x, int y, int width, int height)
        {
            label.AutoSize = false; label.AutoEllipsis = false; label.Anchor = AnchorStyles.Top | AnchorStyles.Left;
            label.SetBounds(x, y, Math.Max(1, width), Math.Max(1, height));
        }

        // Text is measured after localization and font changes; no button is squeezed to make a row fit.
        private void ReflowLayout()
        {
            if (presentationDepth > 0) { reflowPending = true; return; }
            if (reflowing || mainLayout == null || mainLayout.Controls.Count < 7 || Bound("app.title") == null) return;
            reflowing = true;
            try
            {
                int panelWidth = Math.Max(1, mainLayout.ClientSize.Width);
                int contentWidth = Math.Max(120, panelWidth - 40);
                Label title = (Label)Bound("app.title"), subtitle = (Label)Bound("subtitle");
                Label mode = (Label)Bound(daily ? "mode.auto" : "mode.manual");
                Size titleSize = FullText(title), modeSize = FullText(mode);
                int titleHeight = Math.Max(29, titleSize.Height + 2);
                PlaceLabel(title, 55, 0, Math.Min(titleSize.Width + 2, contentWidth - 35), titleHeight);
                bool inlineMode = 55 + titleSize.Width + 18 + modeSize.Width <= panelWidth - 20;
                int modeHeight = Math.Max(22, modeSize.Height + 2);
                int subtitleY = Math.Max(34, titleHeight + 2);
                int subtitleHeight = WrapHeight(subtitle, contentWidth);
                PlaceLabel(subtitle, 20, subtitleY, contentWidth, subtitleHeight);
                int headerHeight = subtitleY + subtitleHeight + 4;
                if (inlineMode) PlaceLabel(mode, panelWidth - 20 - modeSize.Width - 4, Math.Max(0, (titleHeight - modeHeight) / 2), modeSize.Width + 4, modeHeight);
                else { PlaceLabel(mode, 20, headerHeight, contentWidth, WrapHeight(mode, contentWidth)); headerHeight += mode.Height + 3; }
                mainLayout.RowStyles[1].Height = Math.Max(52, headerHeight);

                int summaryHeight = Math.Max(24, WrapHeight(summary, contentWidth));
                PlaceLabel(summary, 20, 0, contentWidth, summaryHeight);
                int countWidth = Math.Max(38, FullText(count).Width + 4);
                int healthWidth = Math.Max(80, contentWidth - countWidth - 12);
                int healthHeight = Math.Max(21, WrapHeight(checkedAt, healthWidth));
                PlaceLabel(checkedAt, 20, summaryHeight + 1, healthWidth, healthHeight);
                PlaceLabel(count, panelWidth - 20 - countWidth, summaryHeight + 1, countWidth, Math.Max(healthHeight, FullText(count).Height + 2));
                mainLayout.RowStyles[2].Height = summaryHeight + Math.Max(healthHeight, count.Height) + 4;

                Panel filter = (Panel)mainLayout.GetControlFromPosition(0, 3);
                Panel tabs = (Panel)providerButtons["ทั้งหมด"].Parent;
                Panel searchPanel = (Panel)searchInput.Parent;
                Label searchLabel = (Label)Bound("search.label");
                filter.Padding = Padding.Empty; tabs.Dock = searchPanel.Dock = DockStyle.None;
                int filterHeight = Math.Max(28, FullText(searchInput).Height + 6);
                int tabLeft = 0;
                foreach (string provider in new[] { "ทั้งหมด", "Codex", "Claude Code" })
                {
                    Button tab = providerButtons[provider]; int tabWidth = Math.Max(52, FullText(tab).Width + 18);
                    tab.Anchor = AnchorStyles.Top | AnchorStyles.Left; tab.AutoEllipsis = false;
                    tab.SetBounds(tabLeft, 0, tabWidth, filterHeight); tabLeft += tabWidth + 3;
                }
                int tabsWidth = tabLeft + 5;
                int searchLabelWidth = FullText(searchLabel).Width + 10;
                int searchMinimum = Math.Max(150, searchLabelWidth + TextRenderer.MeasureText(T("search.placeholder"), searchInput.Font).Width + 24);
                bool stackedSearch = tabsWidth + searchMinimum > contentWidth;
                tabs.SetBounds(20, 2, Math.Min(tabsWidth, contentWidth), filterHeight);
                searchPanel.SetBounds(stackedSearch ? 20 : 20 + tabsWidth, stackedSearch ? filterHeight + 6 : 2,
                    stackedSearch ? contentWidth : contentWidth - tabsWidth, filterHeight);
                searchLabel.AutoEllipsis = false; searchLabel.Width = searchLabelWidth;
                searchPanel.Padding = new Padding(9, 2, 7, 2);
                mainLayout.RowStyles[3].Height = (stackedSearch ? filterHeight * 2 + 6 : filterHeight + 2) + 7;

                int x = 20, y = 8, rowHeight = 0;
                foreach (Button button in new[] { update, check, logs, close })
                {
                    Size natural = FullText(button);
                    int buttonWidth = Math.Max(button == logs || button == close ? 64 : 112, natural.Width + 24);
                    buttonWidth = Math.Min(buttonWidth, contentWidth);
                    int buttonHeight = Math.Max(32, WrapHeight(button, buttonWidth - 16) + 10);
                    if (x > 20 && x + buttonWidth > panelWidth - 20) { x = 20; y += rowHeight + 6; rowHeight = 0; }
                    if (button == close) x = panelWidth - 20 - buttonWidth;
                    button.Anchor = AnchorStyles.Top | AnchorStyles.Left; button.AutoEllipsis = false;
                    button.SetBounds(x, y, buttonWidth, buttonHeight);
                    x += buttonWidth + 10; rowHeight = Math.Max(rowHeight, buttonHeight);
                }
                int scheduleY = y + rowHeight + 3;
                PlaceLabel(schedule, 20, scheduleY, contentWidth, WrapHeight(schedule, contentWidth));
                mainLayout.RowStyles[6].Height = scheduleY + schedule.Height + 5;

                Label detailTitle = (Label)Bound("details.title");
                if (detailTitle != null) { detailTitle.AutoEllipsis = false; detailTitle.Height = FullText(detailTitle).Height + 3; }
                emptyState.AutoEllipsis = false;
                IntegralDetailsBox integral = (IntegralDetailsBox)details;
                int fullLinesHeight = integral.DesiredClientHeight(4);
                mainLayout.RowStyles[5].Height = (detailTitle == null ? 22 : detailTitle.Height) + fullLinesHeight + 8;
                integral.RefreshFormattingRectangle();
            }
            finally { reflowing = false; }
        }
    }
}
