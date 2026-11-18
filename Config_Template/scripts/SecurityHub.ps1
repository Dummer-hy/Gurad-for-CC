<#
  Claude 保护 v9 —— 托盘常驻的桌面工具（普通用户权限运行）
  - 左侧导航：概览 / 引擎与节点 / 网络 / 防护检查 / Claude 进程 / 日志 / 维护
  - 所有慢操作（读状态、调内核接口、查网卡、解析订阅、扫进程）都在后台线程完成，界面线程只负责显示，不卡顿
  - 保护开启时可直接热切换：内置 TUN / 内置系统代理 / Clash Verge，以及锁定节点（不关闭保护）
  - 真正的封锁/放行由 SYSTEM 身份的 ClaudeGuard 守护进程执行；本程序只展示并下发指令
  启动：wscript.exe ClaudeHub.vbs [-Tray]     （-Tray = 开机静默启动，只显示托盘图标）
#>
param(
    [string]$Root = 'C:\ProgramData\ClaudeGuard',
    [string]$StateFile = '',
    [switch]$Tray,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$HubVersion = '10.8'
if (-not $StateFile) { $StateFile = Join-Path $Root 'state\guard_state.json' }
$CmdDir      = Join-Path $Root 'commands'
$LogFile     = Join-Path $Root 'logs\guard.log'
$GuardScript = Join-Path $Root 'bin\ClaudeGuard.ps1'
$Launcher    = Join-Path $Root 'bin\ClaudeHub.vbs'
$SuiteFile   = Join-Path $Root 'suite.json'
$StartupLnk  = Join-Path ([Environment]::GetFolderPath('Startup')) 'Claude保护.lnk'
$SettingsDir  = Join-Path $env:LOCALAPPDATA 'ClaudeGuardHub'
$SettingsFile = Join-Path $SettingsDir 'settings.json'
$VersionsDir  = Join-Path $Root 'versions'
$RollbackScript = Join-Path $Root 'rollback\Rollback.ps1'

# ---------------------------------------------------------------- 单实例
if (-not $SelfTest) {
    $created = $false
    $script:mutex = New-Object System.Threading.Mutex($true, 'Local\ClaudeSecurityHub.v6', [ref]$created)
    $script:showEvt = New-Object System.Threading.EventWaitHandle($false, 'AutoReset', 'Local\ClaudeSecurityHub.v6.Show')
    if (-not $created) {
        if (-not $Tray) { [void]$script:showEvt.Set() }   # 已在运行：唤出已有窗口
        exit
    }
    try {
        Add-Type -ErrorAction SilentlyContinue -TypeDefinition 'using System;using System.Runtime.InteropServices;public class W32{[DllImport("user32.dll")]public static extern bool ShowWindow(IntPtr h,int n);[DllImport("kernel32.dll")]public static extern IntPtr GetConsoleWindow();}'
        $h = [W32]::GetConsoleWindow(); if ($h -ne [IntPtr]::Zero) { [void][W32]::ShowWindow($h, 0) }
    } catch {}
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing

# ================================================================= 界面
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Claude 保护" Width="1100" Height="740" MinWidth="960" MinHeight="620"
        WindowStartupLocation="CenterScreen" Background="#F1F5F9" UseLayoutRounding="True" SnapsToDevicePixels="True"
        TextOptions.TextFormattingMode="Display"
        FontFamily="Microsoft YaHei UI, Segoe UI" FontSize="13" Foreground="#1E293B">
  <Window.Resources>
    <!-- 细滚动条 -->
    <Style x:Key="SbPage" TargetType="RepeatButton">
      <Setter Property="Focusable" Value="False"/><Setter Property="IsTabStop" Value="False"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="SbThumb" TargetType="Thumb">
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="Thumb">
          <Border x:Name="t" Background="#CBD5E1" CornerRadius="4" Margin="2"/>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="t" Property="Background" Value="#94A3B8"/></Trigger>
            <Trigger Property="IsDragging" Value="True"><Setter TargetName="t" Property="Background" Value="#64748B"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="10"/><Setter Property="MinWidth" Value="10"/><Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="ScrollBar">
          <Track x:Name="PART_Track" IsDirectionReversed="True">
            <Track.DecreaseRepeatButton><RepeatButton Command="ScrollBar.PageUpCommand" Style="{StaticResource SbPage}"/></Track.DecreaseRepeatButton>
            <Track.IncreaseRepeatButton><RepeatButton Command="ScrollBar.PageDownCommand" Style="{StaticResource SbPage}"/></Track.IncreaseRepeatButton>
            <Track.Thumb><Thumb Style="{StaticResource SbThumb}"/></Track.Thumb>
          </Track>
        </ControlTemplate></Setter.Value></Setter>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Width" Value="Auto"/><Setter Property="MinWidth" Value="0"/><Setter Property="Height" Value="10"/><Setter Property="MinHeight" Value="10"/>
          <Setter Property="Template"><Setter.Value>
            <ControlTemplate TargetType="ScrollBar">
              <Track x:Name="PART_Track" IsDirectionReversed="False">
                <Track.DecreaseRepeatButton><RepeatButton Command="ScrollBar.PageLeftCommand" Style="{StaticResource SbPage}"/></Track.DecreaseRepeatButton>
                <Track.IncreaseRepeatButton><RepeatButton Command="ScrollBar.PageRightCommand" Style="{StaticResource SbPage}"/></Track.IncreaseRepeatButton>
                <Track.Thumb><Thumb Style="{StaticResource SbThumb}"/></Track.Thumb>
              </Track>
            </ControlTemplate></Setter.Value></Setter>
        </Trigger>
      </Style.Triggers>
    </Style>

    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="White"/><Setter Property="CornerRadius" Value="12"/>
      <Setter Property="BorderBrush" Value="#E2E8F0"/><Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="20,16"/><Setter Property="Margin" Value="0,0,0,14"/>
    </Style>
    <Style x:Key="Tile" TargetType="Border" BasedOn="{StaticResource Card}">
      <Setter Property="Padding" Value="16,13"/><Setter Property="Margin" Value="0,0,12,14"/>
    </Style>
    <Style x:Key="CardTitle" TargetType="TextBlock">
      <Setter Property="FontSize" Value="14"/><Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="#0F172A"/><Setter Property="Margin" Value="0,0,0,12"/>
    </Style>
    <Style x:Key="TileLabel" TargetType="TextBlock"><Setter Property="Foreground" Value="#64748B"/><Setter Property="FontSize" Value="12"/></Style>
    <Style x:Key="TileValue" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#0F172A"/><Setter Property="FontSize" Value="18"/><Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="0,5,0,2"/><Setter Property="TextTrimming" Value="CharacterEllipsis"/>
    </Style>
    <Style x:Key="TileSub" TargetType="TextBlock"><Setter Property="Foreground" Value="#64748B"/><Setter Property="FontSize" Value="12"/><Setter Property="TextTrimming" Value="CharacterEllipsis"/></Style>
    <Style x:Key="Hint" TargetType="TextBlock"><Setter Property="Foreground" Value="#94A3B8"/><Setter Property="FontSize" Value="12"/><Setter Property="TextWrapping" Value="Wrap"/></Style>
    <Style x:Key="Ico" TargetType="TextBlock"><Setter Property="FontFamily" Value="Segoe MDL2 Assets"/><Setter Property="VerticalAlignment" Value="Center"/></Style>

    <!-- 按钮：Tag = 图标字形（可选）；悬停/按下用半透明遮罩，颜色统一 -->
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Cursor" Value="Hand"/><Setter Property="FontSize" Value="13"/><Setter Property="Padding" Value="13,7"/>
      <Setter Property="Background" Value="White"/><Setter Property="BorderBrush" Value="#CBD5E1"/><Setter Property="Foreground" Value="#1E293B"/>
      <Setter Property="BorderThickness" Value="1"/><Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="Button">
          <Grid>
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="7"/>
            <Border x:Name="ov" Background="Transparent" CornerRadius="7"/>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}">
              <TextBlock x:Name="ic" Text="{Binding Tag, RelativeSource={RelativeSource TemplatedParent}}" FontFamily="Segoe MDL2 Assets" FontSize="12.5" VerticalAlignment="Center" Margin="0,1,7,0"/>
              <ContentPresenter VerticalAlignment="Center" RecognizesAccessKey="False"/>
            </StackPanel>
          </Grid>
          <ControlTemplate.Triggers>
            <Trigger Property="Tag" Value="{x:Null}"><Setter TargetName="ic" Property="Visibility" Value="Collapsed"/></Trigger>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ov" Property="Background" Value="#10000000"/></Trigger>
            <Trigger Property="IsPressed" Value="True"><Setter TargetName="ov" Property="Background" Value="#24000000"/></Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="BtnPrimary" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="#2563EB"/><Setter Property="BorderBrush" Value="#2563EB"/><Setter Property="Foreground" Value="White"/>
    </Style>
    <Style x:Key="BtnDanger" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Foreground" Value="#DC2626"/><Setter Property="BorderBrush" Value="#FECACA"/>
    </Style>
    <Style x:Key="BtnGhost" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="Transparent"/><Setter Property="BorderBrush" Value="Transparent"/><Setter Property="Foreground" Value="#2563EB"/><Setter Property="Padding" Value="8,5"/>
    </Style>

    <!-- 侧边导航 -->
    <Style x:Key="Nav" TargetType="RadioButton">
      <Setter Property="Foreground" Value="#CBD5E1"/><Setter Property="FontSize" Value="13.5"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,0,0,3"/><Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="RadioButton">
          <Border x:Name="bd" Background="Transparent" CornerRadius="8" Padding="12,9">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="28"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <TextBlock Text="{Binding Tag, RelativeSource={RelativeSource TemplatedParent}}" FontFamily="Segoe MDL2 Assets" FontSize="15" VerticalAlignment="Center"/>
              <ContentPresenter Grid.Column="1" VerticalAlignment="Center"/>
            </Grid>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#1E293B"/><Setter Property="Foreground" Value="White"/></Trigger>
            <Trigger Property="IsChecked" Value="True"><Setter TargetName="bd" Property="Background" Value="#2563EB"/><Setter Property="Foreground" Value="White"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate></Setter.Value></Setter>
    </Style>

    <!-- 运行模式卡片（Tag = 图标） -->
    <Style x:Key="ModeCard" TargetType="RadioButton">
      <Setter Property="Cursor" Value="Hand"/><Setter Property="FocusVisualStyle" Value="{x:Null}"/><Setter Property="Margin" Value="0,0,10,0"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="RadioButton">
          <Border x:Name="bd" Background="White" BorderBrush="#E2E8F0" BorderThickness="1.5" CornerRadius="10" Padding="14,12">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <Border x:Name="icbg" Width="36" Height="36" CornerRadius="9" Background="#F1F5F9" VerticalAlignment="Top">
                <TextBlock x:Name="ic" Text="{Binding Tag, RelativeSource={RelativeSource TemplatedParent}}" FontFamily="Segoe MDL2 Assets" FontSize="16" Foreground="#475569" HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
              <ContentPresenter Grid.Column="1" Margin="12,0,0,0" VerticalAlignment="Center"/>
              <TextBlock x:Name="chk" Grid.Column="1" Text="&#xE73E;" FontFamily="Segoe MDL2 Assets" FontSize="12" Foreground="#2563EB" HorizontalAlignment="Right" VerticalAlignment="Top" Visibility="Collapsed"/>
            </Grid>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="BorderBrush" Value="#93C5FD"/></Trigger>
            <Trigger Property="IsChecked" Value="True">
              <Setter TargetName="bd" Property="BorderBrush" Value="#2563EB"/><Setter TargetName="bd" Property="Background" Value="#EFF6FF"/>
              <Setter TargetName="icbg" Property="Background" Value="#2563EB"/><Setter TargetName="ic" Property="Foreground" Value="White"/>
              <Setter TargetName="chk" Property="Visibility" Value="Visible"/>
            </Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.5"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate></Setter.Value></Setter>
    </Style>

    <!-- 小胶囊单选 -->
    <Style x:Key="Chip" TargetType="RadioButton">
      <Setter Property="Cursor" Value="Hand"/><Setter Property="FocusVisualStyle" Value="{x:Null}"/><Setter Property="Margin" Value="0,0,8,0"/><Setter Property="Foreground" Value="#334155"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="RadioButton">
          <Border x:Name="bd" Background="White" BorderBrush="#CBD5E1" BorderThickness="1" CornerRadius="15" Padding="13,5">
            <ContentPresenter VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="BorderBrush" Value="#93C5FD"/></Trigger>
            <Trigger Property="IsChecked" Value="True"><Setter TargetName="bd" Property="Background" Value="#2563EB"/><Setter TargetName="bd" Property="BorderBrush" Value="#2563EB"/><Setter Property="Foreground" Value="White"/></Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.5"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="Thin" TargetType="ProgressBar">
      <Setter Property="Height" Value="4"/><Setter Property="Foreground" Value="#2563EB"/><Setter Property="Background" Value="#DBEAFE"/><Setter Property="BorderThickness" Value="0"/>
    </Style>
    <Style TargetType="ComboBox"><Setter Property="Height" Value="34"/><Setter Property="Background" Value="White"/><Setter Property="BorderBrush" Value="#CBD5E1"/><Setter Property="VerticalContentAlignment" Value="Center"/><Setter Property="Padding" Value="10,4"/></Style>
    <!-- 表格（连接 / 内核日志）：行虚拟化，几千行也不卡 -->
    <Style x:Key="Tbl" TargetType="DataGrid">
      <Setter Property="AutoGenerateColumns" Value="False"/><Setter Property="IsReadOnly" Value="True"/>
      <Setter Property="HeadersVisibility" Value="Column"/><Setter Property="GridLinesVisibility" Value="Horizontal"/>
      <Setter Property="HorizontalGridLinesBrush" Value="#F1F5F9"/><Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Background" Value="White"/><Setter Property="RowBackground" Value="White"/>
      <Setter Property="RowHeight" Value="28"/><Setter Property="FontSize" Value="12.5"/><Setter Property="Foreground" Value="#1E293B"/>
      <Setter Property="SelectionMode" Value="Extended"/><Setter Property="SelectionUnit" Value="FullRow"/>
      <Setter Property="CanUserAddRows" Value="False"/><Setter Property="CanUserDeleteRows" Value="False"/><Setter Property="CanUserReorderColumns" Value="False"/>
      <Setter Property="EnableRowVirtualization" Value="True"/><Setter Property="EnableColumnVirtualization" Value="True"/>
      <Setter Property="VirtualizingPanel.IsVirtualizing" Value="True"/><Setter Property="VirtualizingPanel.VirtualizationMode" Value="Recycling"/>
      <Setter Property="ScrollViewer.CanContentScroll" Value="True"/><Setter Property="HorizontalScrollBarVisibility" Value="Auto"/>
    </Style>
    <Style TargetType="DataGridColumnHeader">
      <Setter Property="Background" Value="#F8FAFC"/><Setter Property="Foreground" Value="#64748B"/><Setter Property="FontSize" Value="12"/>
      <Setter Property="Padding" Value="10,7"/><Setter Property="BorderBrush" Value="#E2E8F0"/><Setter Property="BorderThickness" Value="0,0,0,1"/>
    </Style>
    <Style TargetType="DataGridCell">
      <Setter Property="BorderThickness" Value="0"/><Setter Property="Padding" Value="10,0"/><Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="DataGridCell">
          <Border Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}"><ContentPresenter VerticalAlignment="Center"/></Border>
        </ControlTemplate></Setter.Value></Setter>
      <Style.Triggers><Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="#DBEAFE"/><Setter Property="Foreground" Value="#0F172A"/></Trigger></Style.Triggers>
    </Style>
    <Style x:Key="CellText" TargetType="TextBlock"><Setter Property="TextTrimming" Value="CharacterEllipsis"/></Style>
    <Style x:Key="CellTip" TargetType="TextBlock" BasedOn="{StaticResource CellText}">
      <Setter Property="ToolTip" Value="{Binding Text, RelativeSource={RelativeSource Self}}"/>
    </Style>
    <Style x:Key="SearchBox" TargetType="TextBox">
      <Setter Property="Height" Value="32"/><Setter Property="Padding" Value="8,0"/><Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="BorderBrush" Value="#CBD5E1"/><Setter Property="FontSize" Value="12.5"/><Setter Property="Background" Value="White"/>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.ColumnDefinitions><ColumnDefinition Width="216"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>

    <!-- ===================== 侧边栏 ===================== -->
    <Border Background="#0F172A">
      <DockPanel Margin="12,18,12,14">
        <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="8,0,0,24">
          <Border Width="34" Height="34" CornerRadius="9" Background="#2563EB">
            <TextBlock Style="{StaticResource Ico}" Text="&#xEA18;" Foreground="White" FontSize="17" HorizontalAlignment="Center"/>
          </Border>
          <StackPanel Margin="11,0,0,0" VerticalAlignment="Center">
            <TextBlock Text="Claude 保护" FontSize="15" FontWeight="SemiBold" Foreground="White"/>
            <TextBlock x:Name="sideVer" Text="v9" FontSize="11" Foreground="#64748B"/>
          </StackPanel>
        </StackPanel>
        <Border DockPanel.Dock="Bottom" CornerRadius="10" Background="#1E293B" Padding="12,10" Margin="0,10,0,0">
          <StackPanel>
            <StackPanel Orientation="Horizontal">
              <Ellipse x:Name="sideDot" Width="9" Height="9" Fill="#94A3B8" VerticalAlignment="Center"/>
              <TextBlock x:Name="sideStatus" Text="读取中…" Margin="8,0,0,0" FontWeight="SemiBold" Foreground="White"/>
            </StackPanel>
            <TextBlock x:Name="sideMode" Text="" Margin="17,5,0,0" FontSize="11.5" Foreground="#94A3B8" TextTrimming="CharacterEllipsis"/>
            <TextBlock x:Name="sideIp" Text="" Margin="17,2,0,0" FontSize="11.5" Foreground="#94A3B8" TextTrimming="CharacterEllipsis"/>
          </StackPanel>
        </Border>
        <StackPanel>
          <RadioButton x:Name="navOverview" Style="{StaticResource Nav}" GroupName="nav" Tag="&#xE80F;" Content="概览" IsChecked="True"/>
          <RadioButton x:Name="navConfig"   Style="{StaticResource Nav}" GroupName="nav" Tag="&#xE713;" Content="引擎与节点"/>
          <RadioButton x:Name="navNetwork"  Style="{StaticResource Nav}" GroupName="nav" Tag="&#xE839;" Content="网络"/>
          <RadioButton x:Name="navConns"    Style="{StaticResource Nav}" GroupName="nav" Tag="&#xE71B;" Content="连接"/>
          <RadioButton x:Name="navCoreLog"  Style="{StaticResource Nav}" GroupName="nav" Tag="&#xE9D9;" Content="内核日志"/>
          <RadioButton x:Name="navProtect"  Style="{StaticResource Nav}" GroupName="nav" Tag="&#xEA18;" Content="防护检查"/>
          <RadioButton x:Name="navProcs"    Style="{StaticResource Nav}" GroupName="nav" Tag="&#xE7C4;" Content="Claude 进程"/>
          <RadioButton x:Name="navLogs"     Style="{StaticResource Nav}" GroupName="nav" Tag="&#xE8A5;" Content="保护日志"/>
          <RadioButton x:Name="navMaint"    Style="{StaticResource Nav}" GroupName="nav" Tag="&#xE90F;" Content="维护"/>
        </StackPanel>
      </DockPanel>
    </Border>

    <Grid Grid.Column="1">
      <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
      <!-- 顶栏 -->
      <Border Background="White" BorderBrush="#E2E8F0" BorderThickness="0,0,0,1" Padding="26,13,22,13">
        <Grid>
          <StackPanel Margin="0,0,220,0">
            <TextBlock x:Name="hdrTitle" Text="概览" FontSize="19" FontWeight="SemiBold" Foreground="#0F172A"/>
            <TextBlock x:Name="hdrSub" Text="" Foreground="#64748B" FontSize="12.5" Margin="0,3,0,0" TextTrimming="CharacterEllipsis"/>
          </StackPanel>
          <Border x:Name="hdrChip" HorizontalAlignment="Right" VerticalAlignment="Center" CornerRadius="15" Padding="12,6" Background="#F1F5F9">
            <StackPanel Orientation="Horizontal">
              <Ellipse x:Name="hdrDot" Width="8" Height="8" Fill="#94A3B8" VerticalAlignment="Center"/>
              <TextBlock x:Name="hdrStatus" Text="读取中" Margin="7,0,0,0" FontWeight="SemiBold" FontSize="12.5"/>
              <TextBlock x:Name="hdrMode" Text="" Margin="8,0,0,0" FontSize="12.5" Foreground="#64748B"/>
            </StackPanel>
          </Border>
        </Grid>
      </Border>

      <Grid Grid.Row="1">
      <!-- ===================== 概览 ===================== -->
      <ScrollViewer x:Name="pageOverview" VerticalScrollBarVisibility="Auto">
        <StackPanel Margin="24,18,24,8">
          <Border Style="{StaticResource Card}" Padding="22,18">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <Border x:Name="dot" Width="60" Height="60" CornerRadius="30" Background="#94A3B8" VerticalAlignment="Center">
                <TextBlock x:Name="dotGlyph" Style="{StaticResource Ico}" Text="&#xEA18;" Foreground="White" FontSize="26" HorizontalAlignment="Center"/>
              </Border>
              <StackPanel Grid.Column="1" Margin="18,0,16,0" VerticalAlignment="Center">
                <TextBlock x:Name="statusTitle" Text="正在读取状态…" FontSize="22" FontWeight="SemiBold" Foreground="#0F172A"/>
                <TextBlock x:Name="statusSub" Text="" Foreground="#475569" Margin="0,4,0,0" TextWrapping="Wrap"/>
                <StackPanel x:Name="busyBox" Margin="0,10,0,0" Visibility="Collapsed">
                  <TextBlock x:Name="busyText" Foreground="#1D4ED8" FontSize="12.5" TextWrapping="Wrap"/>
                  <ProgressBar x:Name="busyBar" Style="{StaticResource Thin}" IsIndeterminate="True" Margin="0,7,0,0" Width="420" HorizontalAlignment="Left"/>
                </StackPanel>
              </StackPanel>
              <StackPanel Grid.Column="2" VerticalAlignment="Center">
                <Button x:Name="btnMain" Style="{StaticResource BtnPrimary}" Tag="&#xE7E8;" Content="开启保护" MinWidth="150" Padding="20,10" FontSize="14.5" FontWeight="SemiBold"/>
                <Button x:Name="btnProbe" Style="{StaticResource Btn}" Tag="&#xE72C;" Content="立即检查出口" Margin="0,8,0,0"/>
                <TextBlock x:Name="probeMsg" FontSize="12" TextWrapping="Wrap" MaxWidth="190" Margin="2,6,0,0" Visibility="Collapsed"/>
              </StackPanel>
            </Grid>
          </Border>

          <Border Style="{StaticResource Card}" Padding="18,14,8,14">
            <StackPanel>
              <Grid Margin="0,0,10,10">
                <TextBlock Style="{StaticResource CardTitle}" Margin="0" Text="运行模式"/>
                <TextBlock x:Name="modeHint" HorizontalAlignment="Right" Foreground="#64748B" FontSize="12" VerticalAlignment="Center"/>
              </Grid>
              <UniformGrid Columns="3">
                <RadioButton x:Name="mTun" Style="{StaticResource ModeCard}" GroupName="m1" Tag="&#xE7F4;">
                  <StackPanel><TextBlock Text="内置 · TUN" FontWeight="SemiBold" FontSize="13.5" Foreground="#0F172A"/><TextBlock Text="整机接管，推荐" FontSize="11.5" Foreground="#64748B" Margin="0,2,0,0"/><TextBlock x:Name="mTunState" FontSize="11.5" Margin="0,3,0,0"/></StackPanel>
                </RadioButton>
                <RadioButton x:Name="mSys" Style="{StaticResource ModeCard}" GroupName="m1" Tag="&#xE774;">
                  <StackPanel><TextBlock Text="内置 · 系统代理" FontWeight="SemiBold" FontSize="13.5" Foreground="#0F172A"/><TextBlock Text="只有认代理的程序能联网" FontSize="11.5" Foreground="#64748B" Margin="0,2,0,0"/><TextBlock x:Name="mSysState" FontSize="11.5" Margin="0,3,0,0"/></StackPanel>
                </RadioButton>
                <RadioButton x:Name="mVerge" Style="{StaticResource ModeCard}" GroupName="m1" Tag="&#xE8AF;">
                  <StackPanel><TextBlock Text="Clash Verge" FontWeight="SemiBold" FontSize="13.5" Foreground="#0F172A"/><TextBlock Text="借用外部 Clash（旧方式）" FontSize="11.5" Foreground="#64748B" Margin="0,2,0,0"/><TextBlock x:Name="mVergeState" FontSize="11.5" Margin="0,3,0,0"/></StackPanel>
                </RadioButton>
              </UniformGrid>
            </StackPanel>
          </Border>

          <Grid Margin="0,0,-12,0">
            <UniformGrid Columns="4">
              <Border Style="{StaticResource Tile}">
                <StackPanel>
                  <TextBlock Style="{StaticResource TileLabel}" Text="出口"/>
                  <TextBlock x:Name="tIp" Style="{StaticResource TileValue}" Text="-"/>
                  <TextBlock x:Name="tIpSub" Style="{StaticResource TileSub}" Text="-"/>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource Tile}">
                <Grid>
                  <StackPanel>
                    <TextBlock Style="{StaticResource TileLabel}" Text="出口检测用时"/>
                    <TextBlock x:Name="tLat" Style="{StaticResource TileValue}" Text="-"/>
                    <TextBlock x:Name="tLatSub" Style="{StaticResource TileSub}" Text="-"/>
                  </StackPanel>
                  <Canvas Width="70" Height="26" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,2,0,0">
                    <Polyline x:Name="sparkLine" Stroke="#2563EB" StrokeThickness="1.6" StrokeLineJoin="Round"/>
                  </Canvas>
                </Grid>
              </Border>
              <Border Style="{StaticResource Tile}">
                <StackPanel>
                  <TextBlock Style="{StaticResource TileLabel}" Text="实时流量（经节点）"/>
                  <TextBlock x:Name="tSpeed" Style="{StaticResource TileValue}" Text="-"/>
                  <TextBlock x:Name="tSpeedSub" Style="{StaticResource TileSub}" Text="-"/>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource Tile}">
                <StackPanel>
                  <TextBlock Style="{StaticResource TileLabel}" Text="订阅流量"/>
                  <TextBlock x:Name="tQuota" Style="{StaticResource TileValue}" Text="-"/>
                  <TextBlock x:Name="tQuotaSub" Style="{StaticResource TileSub}" Text="-"/>
                </StackPanel>
              </Border>
            </UniformGrid>
          </Grid>

          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="14"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <Grid>
                  <TextBlock Style="{StaticResource CardTitle}" Text="节点与配置"/>
                  <Button x:Name="btnGoConfig" Style="{StaticResource BtnGhost}" Content="更改" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,-5,-6,0"/>
                </Grid>
                <StackPanel x:Name="kvNode"/>
              </StackPanel>
            </Border>
            <Border Grid.Column="2" Style="{StaticResource Card}">
              <StackPanel>
                <Grid>
                  <TextBlock Style="{StaticResource CardTitle}" Text="防护摘要"/>
                  <TextBlock x:Name="checkSummary" HorizontalAlignment="Right" FontSize="12" Foreground="#64748B"/>
                </Grid>
                <StackPanel x:Name="panelLeak"/>
              </StackPanel>
            </Border>
          </Grid>

          <Border Style="{StaticResource Card}">
            <StackPanel>
              <Grid>
                <TextBlock Style="{StaticResource CardTitle}" Text="最近事件"/>
                <Button x:Name="btnAllLogs" Style="{StaticResource BtnGhost}" Content="全部日志" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,-5,-6,0"/>
              </Grid>
              <StackPanel x:Name="panelEvents"/>
            </StackPanel>
          </Border>
        </StackPanel>
      </ScrollViewer>

      <!-- ===================== 引擎与节点 ===================== -->
      <ScrollViewer x:Name="pageConfig" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
        <StackPanel Margin="24,18,24,8">
          <Border Style="{StaticResource Card}" Padding="20,16,10,16">
            <StackPanel>
              <TextBlock Style="{StaticResource CardTitle}" Text="运行模式"/>
              <TextBlock x:Name="valEngine" Text="-" TextWrapping="Wrap" FontSize="13.5" FontWeight="SemiBold" Margin="0,-4,10,12"/>
              <UniformGrid Columns="3">
                <RadioButton x:Name="cTun" Style="{StaticResource ModeCard}" GroupName="m2" Tag="&#xE7F4;">
                  <StackPanel><TextBlock Text="内置 · TUN（推荐）" FontWeight="SemiBold" FontSize="13.5" Foreground="#0F172A"/><TextBlock Text="自带内核接管整台电脑的网络，所有程序都经锁定节点，不需要打开 Clash Verge。" TextWrapping="Wrap" FontSize="11.5" Foreground="#64748B" Margin="0,3,0,0"/><TextBlock x:Name="cTunState" FontSize="11.5" Margin="0,4,0,0"/></StackPanel>
                </RadioButton>
                <RadioButton x:Name="cSys" Style="{StaticResource ModeCard}" GroupName="m2" Tag="&#xE774;">
                  <StackPanel><TextBlock Text="内置 · 系统代理" FontWeight="SemiBold" FontSize="13.5" Foreground="#0F172A"/><TextBlock Text="只有认系统代理的程序（浏览器、Claude 桌面版）能联网，其余程序直接断网，不会直连。" TextWrapping="Wrap" FontSize="11.5" Foreground="#64748B" Margin="0,3,0,0"/><TextBlock x:Name="cSysState" FontSize="11.5" Margin="0,4,0,0"/></StackPanel>
                </RadioButton>
                <RadioButton x:Name="cVerge" Style="{StaticResource ModeCard}" GroupName="m2" Tag="&#xE8AF;">
                  <StackPanel><TextBlock Text="Clash Verge（旧）" FontWeight="SemiBold" FontSize="13.5" Foreground="#0F172A"/><TextBlock Text="借用电脑上的 Clash Verge(TUN) 运行，开启保护时给它套用严格配置。" TextWrapping="Wrap" FontSize="11.5" Foreground="#64748B" Margin="0,3,0,0"/><TextBlock x:Name="cVergeState" FontSize="11.5" Margin="0,4,0,0"/></StackPanel>
                </RadioButton>
              </UniformGrid>
              <TextBlock x:Name="engineHint" Style="{StaticResource Hint}" Margin="0,10,10,0"/>
              <StackPanel x:Name="panelVergeMode" Orientation="Horizontal" Margin="0,10,0,0">
                <TextBlock Text="Clash Verge 配置" Foreground="#64748B" VerticalAlignment="Center" Width="120"/>
                <RadioButton x:Name="rbStrict" Style="{StaticResource Chip}" GroupName="cfg" Content="切换配置（推荐）"/>
                <RadioButton x:Name="rbKeep" Style="{StaticResource Chip}" GroupName="cfg" Content="保持当前配置"/>
              </StackPanel>
              <Border x:Name="boxConflict" Background="#FEF3C7" CornerRadius="8" Padding="12,9" Margin="0,12,10,0" Visibility="Collapsed">
                <Grid>
                  <TextBlock x:Name="txtConflict" TextWrapping="Wrap" Foreground="#92400E" FontSize="12.5" VerticalAlignment="Center" Margin="0,0,140,0"/>
                  <Button x:Name="btnKillConflict" Style="{StaticResource BtnDanger}" Tag="&#xE711;" Content="结束冲突程序" HorizontalAlignment="Right" Padding="10,5"/>
                </Grid>
              </Border>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <Grid>
                <TextBlock Style="{StaticResource CardTitle}" Text="节点来源与订阅"/>
                <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,-5,0,0">
                  <Button x:Name="btnImport" Style="{StaticResource Btn}" Tag="&#xE8E5;" Content="导入本地配置…" Margin="0,0,8,0" Padding="11,6"/>
                  <Button x:Name="btnSub" Style="{StaticResource BtnPrimary}" Tag="&#xE895;" Content="更新订阅" Padding="13,6"/>
                </StackPanel>
              </Grid>
              <StackPanel x:Name="panelSource" Orientation="Horizontal" Margin="0,0,0,10">
                <TextBlock Text="节点来源" Foreground="#64748B" VerticalAlignment="Center" Width="120"/>
                <RadioButton x:Name="rbSrcBaiyang" Style="{StaticResource Chip}" GroupName="src" Content="白羊订阅"/>
                <RadioButton x:Name="rbSrcLocal" Style="{StaticResource Chip}" GroupName="src" Content="导入的本地配置"/>
              </StackPanel>
              <StackPanel x:Name="kvSub"/>
              <TextBlock x:Name="subHint" Style="{StaticResource Hint}" Margin="0,8,0,0"/>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Style="{StaticResource CardTitle}" Text="锁定节点"/>
              <StackPanel x:Name="kvPin"/>
              <TextBlock Text="选择要锁定的节点" Foreground="#64748B" Margin="0,12,0,5"/>
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <ComboBox x:Name="cbNodes" FontSize="13" Margin="0,0,10,0"/>
                <Button x:Name="btnPin" Grid.Column="1" Style="{StaticResource BtnPrimary}" Tag="&#xE72E;" Content="锁定此节点" Padding="14,7"/>
              </Grid>
              <TextBlock x:Name="pinHint" Style="{StaticResource Hint}" Margin="0,8,0,0"/>
            </StackPanel>
          </Border>
        </StackPanel>
      </ScrollViewer>

      <!-- ===================== 网络 ===================== -->
      <ScrollViewer x:Name="pageNetwork" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
        <StackPanel Margin="24,18,24,8">
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <Grid>
                <TextBlock Style="{StaticResource CardTitle}" Text="连接测试"/>
                <Button x:Name="btnTest" Style="{StaticResource BtnPrimary}" Tag="&#xE768;" Content="开始测试" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,-5,0,0" Padding="13,6"/>
              </Grid>
              <StackPanel x:Name="panelTest"/>
              <TextBlock Style="{StaticResource Hint}" Margin="0,6,0,0" Text="通过当前网络访问以下站点，测量完整 HTTPS 请求用时，并读取服务端看到的出口地区。保护没有正常放行时不访问 Claude 的站点。"/>
            </StackPanel>
          </Border>
          <TextBlock x:Name="netStamp" Foreground="#64748B" FontSize="12" Margin="4,0,0,10" Text="正在读取实时状态…"/>
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="14"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <Border Style="{StaticResource Card}" VerticalAlignment="Top">
              <StackPanel>
                <TextBlock x:Name="titCore" Style="{StaticResource CardTitle}" Text="内核"/>
                <StackPanel x:Name="kvCore"/>
              </StackPanel>
            </Border>
            <StackPanel Grid.Column="2">
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock x:Name="titTun" Style="{StaticResource CardTitle}" Text="TUN 隧道"/>
                  <StackPanel x:Name="kvTun"/>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Style="{StaticResource CardTitle}" Text="本机网卡"/>
                  <StackPanel x:Name="kvPhys"/>
                </StackPanel>
              </Border>
            </StackPanel>
          </Grid>
        </StackPanel>
      </ScrollViewer>

      <!-- ===================== 防护检查 ===================== -->
      <ScrollViewer x:Name="pageProtect" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
        <StackPanel Margin="24,18,24,8">
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Style="{StaticResource CardTitle}" Text="防泄露结论"/>
              <StackPanel x:Name="panelLeak2"/>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <Grid>
                <TextBlock Style="{StaticResource CardTitle}" Text="全部检查项"/>
                <TextBlock x:Name="checkSummary2" HorizontalAlignment="Right" FontSize="12" Foreground="#64748B"/>
              </Grid>
              <StackPanel x:Name="panelChecks"/>
            </StackPanel>
          </Border>
        </StackPanel>
      </ScrollViewer>

      <!-- ===================== 连接 ===================== -->
      <Grid x:Name="pageConns" Visibility="Collapsed" Margin="24,16,24,16">
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
        <DockPanel LastChildFill="False">
          <RadioButton x:Name="cnActive" DockPanel.Dock="Left" Style="{StaticResource Chip}" GroupName="cn" Content="活动" IsChecked="True"/>
          <RadioButton x:Name="cnClosed" DockPanel.Dock="Left" Style="{StaticResource Chip}" GroupName="cn" Content="已关闭"/>
          <Grid DockPanel.Dock="Left" Margin="6,0,0,0">
            <TextBox x:Name="cnSearch" Style="{StaticResource SearchBox}" Width="230"/>
            <TextBlock x:Name="cnSearchHint" Text="筛选：程序 / 域名 / 规则" IsHitTestVisible="False" Foreground="#94A3B8" Margin="10,0,0,0" VerticalAlignment="Center" FontSize="12.5"/>
          </Grid>
          <Button x:Name="btnConnCloseAll" DockPanel.Dock="Right" Style="{StaticResource BtnDanger}" Tag="&#xE74D;" Content="全部关闭" Padding="11,6"/>
          <Button x:Name="btnConnClose" DockPanel.Dock="Right" Style="{StaticResource Btn}" Tag="&#xE711;" Content="关闭选中" Padding="11,6" Margin="0,0,8,0"/>
          <Button x:Name="btnConnPause" DockPanel.Dock="Right" Style="{StaticResource Btn}" Tag="&#xE769;" Content="暂停" Padding="11,6" Margin="0,0,8,0"/>
        </DockPanel>
        <StackPanel Grid.Row="1" Margin="2,10,0,10">
          <TextBlock x:Name="cnSummary" Foreground="#334155" FontSize="12.5" Text="正在连接内核…" TextTrimming="CharacterEllipsis"/>
          <TextBlock x:Name="cnTop" Foreground="#64748B" FontSize="12" Margin="0,3,0,0" TextTrimming="CharacterEllipsis"/>
        </StackPanel>
        <Border Grid.Row="2" Background="White" CornerRadius="10" BorderBrush="#E2E8F0" BorderThickness="1" Padding="1">
          <Grid>
            <DataGrid x:Name="gridConns" Style="{StaticResource Tbl}">
              <DataGrid.Columns>
                <DataGridTextColumn Header="程序" Binding="{Binding proc}" Width="120" ElementStyle="{StaticResource CellTip}"/>
                <DataGridTextColumn Header="目标" Binding="{Binding dest}" Width="2*" MinWidth="150" ElementStyle="{StaticResource CellTip}"/>
                <DataGridTextColumn Header="类型" Binding="{Binding net}" Width="84"/>
                <DataGridTextColumn Header="规则" Binding="{Binding rule}" Width="*" MinWidth="80" ElementStyle="{StaticResource CellTip}"/>
                <DataGridTextColumn Header="出口" Binding="{Binding chain}" Width="*" MinWidth="90" ElementStyle="{StaticResource CellTip}"/>
                <DataGridTextColumn Header="↓ 速度" Binding="{Binding dlsT}" SortMemberPath="dls" Width="80"/>
                <DataGridTextColumn Header="↑ 速度" Binding="{Binding ulsT}" SortMemberPath="uls" Width="80"/>
                <DataGridTextColumn Header="↓ 下载" Binding="{Binding dlT}" SortMemberPath="dl" Width="76"/>
                <DataGridTextColumn Header="↑ 上传" Binding="{Binding ulT}" SortMemberPath="ul" Width="76"/>
                <DataGridTextColumn Header="时长" Binding="{Binding durT}" SortMemberPath="start" Width="86"/>
              </DataGrid.Columns>
            </DataGrid>
            <DataGrid x:Name="gridClosed" Style="{StaticResource Tbl}" Visibility="Collapsed">
              <DataGrid.Columns>
                <DataGridTextColumn Header="关闭于" Binding="{Binding endT}" SortMemberPath="endTicks" Width="70"/>
                <DataGridTextColumn Header="程序" Binding="{Binding proc}" Width="110" ElementStyle="{StaticResource CellTip}"/>
                <DataGridTextColumn Header="目标" Binding="{Binding dest}" Width="2*" MinWidth="140" ElementStyle="{StaticResource CellTip}"/>
                <DataGridTextColumn Header="出口" Binding="{Binding chain}" Width="*" MinWidth="80" ElementStyle="{StaticResource CellTip}"/>
                <DataGridTextColumn Header="↓ 下载" Binding="{Binding dlT}" SortMemberPath="dl" Width="74"/>
                <DataGridTextColumn Header="↑ 上传" Binding="{Binding ulT}" SortMemberPath="ul" Width="74"/>
                <DataGridTextColumn Header="时长" Binding="{Binding durT}" SortMemberPath="durS" Width="80"/>
                <DataGridTextColumn Header="断开原因" Binding="{Binding reason}" Width="2*" MinWidth="160" ElementStyle="{StaticResource CellTip}"/>
              </DataGrid.Columns>
            </DataGrid>
          </Grid>
        </Border>
      </Grid>

      <!-- ===================== 内核日志 ===================== -->
      <Grid x:Name="pageCoreLog" Visibility="Collapsed" Margin="24,16,24,16">
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
        <DockPanel LastChildFill="False">
          <RadioButton x:Name="lvAll"  DockPanel.Dock="Left" Style="{StaticResource Chip}" GroupName="lv" Content="全部" IsChecked="True"/>
          <RadioButton x:Name="lvWarn" DockPanel.Dock="Left" Style="{StaticResource Chip}" GroupName="lv" Content="警告和错误"/>
          <RadioButton x:Name="lvErr"  DockPanel.Dock="Left" Style="{StaticResource Chip}" GroupName="lv" Content="只看错误"/>
          <Grid DockPanel.Dock="Left" Margin="6,0,0,0">
            <TextBox x:Name="clSearch" Style="{StaticResource SearchBox}" Width="230"/>
            <TextBlock x:Name="clSearchHint" Text="搜索：域名 / IP / 关键字" IsHitTestVisible="False" Foreground="#94A3B8" Margin="10,0,0,0" VerticalAlignment="Center" FontSize="12.5"/>
          </Grid>
          <Button x:Name="btnLogClear" DockPanel.Dock="Right" Style="{StaticResource Btn}" Tag="&#xE74D;" Content="清空" Padding="11,6"/>
          <Button x:Name="btnLogCopy" DockPanel.Dock="Right" Style="{StaticResource Btn}" Tag="&#xE8C8;" Content="复制" Padding="11,6" Margin="0,0,8,0"/>
          <Button x:Name="btnLogPause" DockPanel.Dock="Right" Style="{StaticResource Btn}" Tag="&#xE769;" Content="暂停" Padding="11,6" Margin="0,0,8,0"/>
        </DockPanel>
        <TextBlock Grid.Row="1" x:Name="clSummary" Margin="2,10,0,10" Foreground="#334155" FontSize="12.5" Text="正在连接内核日志…" TextTrimming="CharacterEllipsis"/>
        <Border Grid.Row="2" Background="White" CornerRadius="10" BorderBrush="#E2E8F0" BorderThickness="1" Padding="1">
          <DataGrid x:Name="gridLog" Style="{StaticResource Tbl}">
            <DataGrid.RowStyle>
              <Style TargetType="DataGridRow">
                <Style.Triggers>
                  <DataTrigger Binding="{Binding lv}" Value="warning"><Setter Property="Foreground" Value="#B45309"/></DataTrigger>
                  <DataTrigger Binding="{Binding lv}" Value="error"><Setter Property="Foreground" Value="#DC2626"/></DataTrigger>
                  <DataTrigger Binding="{Binding lv}" Value="debug"><Setter Property="Foreground" Value="#94A3B8"/></DataTrigger>
                </Style.Triggers>
              </Style>
            </DataGrid.RowStyle>
            <DataGrid.Columns>
              <DataGridTextColumn Header="时间" Binding="{Binding time}" SortMemberPath="seq" Width="78"/>
              <DataGridTextColumn Header="级别" Binding="{Binding lvT}" SortMemberPath="lvn" Width="56"/>
              <DataGridTextColumn Header="内容" Binding="{Binding msg}" Width="*" ElementStyle="{StaticResource CellTip}"/>
            </DataGrid.Columns>
          </DataGrid>
        </Border>
      </Grid>

      <!-- ===================== Claude 进程 ===================== -->
      <ScrollViewer x:Name="pageProcs" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
        <StackPanel Margin="24,18,24,8">
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <Grid>
                <TextBlock x:Name="procSummary" Style="{StaticResource CardTitle}" Text="-"/>
                <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,-5,0,0">
                  <Button x:Name="btnProcRefresh" Style="{StaticResource Btn}" Tag="&#xE72C;" Content="刷新" Margin="0,0,8,0" Padding="11,6"/>
                  <Button x:Name="btnKill" Style="{StaticResource BtnDanger}" Tag="&#xE711;" Content="结束所有 Claude 程序" Padding="11,6"/>
                </StackPanel>
              </Grid>
              <StackPanel x:Name="panelProcs"/>
            </StackPanel>
          </Border>
        </StackPanel>
      </ScrollViewer>

      <!-- ===================== 日志 ===================== -->
      <ScrollViewer x:Name="pageLogs" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
        <StackPanel Margin="24,18,24,8">
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <Grid Margin="0,0,0,10">
                <CheckBox x:Name="chkWarnOnly" Content="只看警告和错误" VerticalAlignment="Center" Foreground="#334155"/>
                <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                  <Button x:Name="btnLog"  Style="{StaticResource Btn}" Tag="&#xE8E5;" Content="打开日志文件" Margin="0,0,8,0" Padding="11,6"/>
                  <Button x:Name="btnCopy" Style="{StaticResource Btn}" Tag="&#xE8C8;" Content="复制诊断信息" Padding="11,6"/>
                </StackPanel>
              </Grid>
              <StackPanel x:Name="panelAllEvents"/>
            </StackPanel>
          </Border>
        </StackPanel>
      </ScrollViewer>

      <!-- ===================== 维护 ===================== -->
      <ScrollViewer x:Name="pageMaint" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
        <StackPanel Margin="24,18,24,8">
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Style="{StaticResource CardTitle}" Text="版本"/>
              <StackPanel x:Name="kvVer"/>
              <TextBlock x:Name="valVer" Text="-" TextWrapping="Wrap" Margin="0,10,0,10"/>
              <WrapPanel>
                <Button x:Name="btnUpdate" Style="{StaticResource BtnPrimary}" Tag="&#xE896;" Content="更新到最新版" Margin="0,0,8,8" Padding="14,7"/>
                <Button x:Name="btnRepair" Style="{StaticResource Btn}" Tag="&#xE90F;" Content="完整修复（重新部署）" Margin="0,0,8,8"/>
              </WrapPanel>
              <TextBlock Style="{StaticResource Hint}" Text="更新：替换程序文件，不断网、不中断 Claude（守护热启动），更新前自动保存当前版本。完整修复：针对 Clash Verge 引擎重写严格配置并重装守护，会短暂断网，仅在开启保护一直失败时使用。"/>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Style="{StaticResource CardTitle}" Text="版本回退"/>
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <ComboBox x:Name="cbVersions" FontSize="13" Margin="0,0,10,0"/>
                <Button x:Name="btnRollback" Grid.Column="1" Style="{StaticResource Btn}" Tag="&#xE7A7;" Content="回退到此版本" Padding="12,7"/>
              </Grid>
              <TextBlock Style="{StaticResource Hint}" Margin="0,8,0,0"
                         Text="每次「更新到最新版」前都会自动保存当前版本（保留最近 5 个）。回退会先关闭保护，回退后需要重新开启；回退前的版本也会保存，可以再回来。控制台打不开时，用开始菜单「Claude保护 → 回退到旧版本」。"/>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Style="{StaticResource CardTitle}" Text="应急工具"/>
              <WrapPanel>
                <Button x:Name="btnForce"  Style="{StaticResource Btn}" Tag="&#xE72E;" Content="强制断网" Margin="0,0,8,8"/>
                <Button x:Name="btnRescue" Style="{StaticResource BtnDanger}" Tag="&#xE7BA;" Content="应急恢复网络" Margin="0,0,8,8"/>
              </WrapPanel>
              <TextBlock Style="{StaticResource Hint}" Text="强制断网：整台电脑立即断网，直到手动取消。应急恢复：「关闭保护」无效时使用，撤销全部防火墙限制并停用守护（开始菜单「Claude保护」文件夹里也有一个，控制台打不开时用）。"/>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Style="{StaticResource CardTitle}" Text="启动"/>
              <CheckBox x:Name="chkAuto" Content="开机时自动在后台运行（只显示托盘图标）" Foreground="#334155"/>
              <TextBlock Style="{StaticResource Hint}" Margin="0,8,0,0" Text="关闭窗口后程序会在屏幕右下角托盘继续运行。保护由后台守护服务执行，退出本程序不影响保护。"/>
            </StackPanel>
          </Border>
        </StackPanel>
      </ScrollViewer>
      </Grid>
    </Grid>
  </Grid>
</Window>
'@

$reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
$win = [System.Windows.Markup.XamlReader]::Load($reader)
function C([string]$n) { $win.FindName($n) }
foreach ($n in @('dot','dotGlyph','statusTitle','statusSub','busyBox','busyText','busyBar','btnMain','btnProbe','probeMsg',
                 'mTun','mSys','mVerge','mTunState','mSysState','mVergeState','modeHint',
                 'cTun','cSys','cVerge','cTunState','cSysState','cVergeState',
                 'tIp','tIpSub','tLat','tLatSub','sparkLine','tSpeed','tSpeedSub','tQuota','tQuotaSub',
                 'kvNode','checkSummary','panelLeak','panelEvents','btnAllLogs','btnGoConfig',
                 'btnTest','panelTest','kvCore','kvTun','kvPhys','titCore','titTun','netStamp',
                 'cnActive','cnClosed','cnSearch','cnSearchHint','btnConnCloseAll','btnConnClose','btnConnPause','cnSummary','cnTop','gridConns','gridClosed',
                 'lvAll','lvWarn','lvErr','clSearch','clSearchHint','btnLogClear','btnLogCopy','btnLogPause','clSummary','gridLog',
                 'valEngine','engineHint','panelVergeMode','rbStrict','rbKeep','boxConflict','txtConflict','btnKillConflict',
                 'btnImport','btnSub','panelSource','rbSrcBaiyang','rbSrcLocal','kvSub','subHint',
                 'kvPin','cbNodes','btnPin','pinHint',
                 'panelLeak2','checkSummary2','panelChecks',
                 'procSummary','btnProcRefresh','btnKill','panelProcs',
                 'chkWarnOnly','btnLog','btnCopy','panelAllEvents',
                 'kvVer','valVer','btnUpdate','btnRepair','cbVersions','btnRollback','btnForce','btnRescue','chkAuto',
                 'sideVer','sideDot','sideStatus','sideMode','sideIp','hdrTitle','hdrSub','hdrDot','hdrStatus','hdrMode','hdrChip')) {
    Set-Variable -Name $n -Value (C $n) -Scope Script
}
$sideVer.Text = "v$HubVersion"

$Pages = [ordered]@{
    overview = @{ nav = (C 'navOverview'); page = (C 'pageOverview'); title = '概览';       sub = '保护状态、运行模式、出口与流量一览' }
    config   = @{ nav = (C 'navConfig');   page = (C 'pageConfig');   title = '引擎与节点'; sub = '运行模式、节点来源与锁定节点。保护开启时直接热切换，不用关闭保护。' }
    network  = @{ nav = (C 'navNetwork');  page = (C 'pageNetwork');  title = '网络';       sub = '内核、隧道与本机网卡的实时状态，以及到 Claude 的连接测试' }
    conns    = @{ nav = (C 'navConns');    page = (C 'pageConns');    title = '连接';       sub = '经过内核的每一条连接：哪个程序、连到哪里、走哪条规则和出口；断开的连接记在「已关闭」里，附断开原因' }
    corelog  = @{ nav = (C 'navCoreLog');  page = (C 'pageCoreLog');  title = '内核日志';   sub = '内核的实时日志：每条连接匹配的规则、拨号失败与报错（和 Clash Verge 的「日志」相同）' }
    protect  = @{ nav = (C 'navProtect');  page = (C 'pageProtect');  title = '防护检查';   sub = '守护服务每 2 秒自检一次；任一硬性检查失败都会立即拦截 Claude' }
    procs    = @{ nav = (C 'navProcs');    page = (C 'pageProcs');    title = 'Claude 进程'; sub = '正在运行的 Claude 桌面版与 Claude Code；退出后仍有残留可以一键结束' }
    logs     = @{ nav = (C 'navLogs');     page = (C 'pageLogs');     title = '保护日志';       sub = '守护服务记录的事件（最近 150 条，最新在上）' }
    maint    = @{ nav = (C 'navMaint');    page = (C 'pageMaint');    title = '维护';       sub = '版本更新、回退与应急工具' }
}
$script:page = 'overview'

$bcv = New-Object System.Windows.Media.BrushConverter
$script:brushes = @{}
function B([string]$hex) { if (-not $script:brushes.ContainsKey($hex)) { $b = $bcv.ConvertFromString($hex); $b.Freeze(); $script:brushes[$hex] = $b }; return $script:brushes[$hex] }

# ================================================================= 共用小工具（界面线程与后台线程都用）
$HelperText = @'
function Format-Bytes([double]$n) {
    if ($n -lt 0) { return '-' }
    $u = @('B', 'KB', 'MB', 'GB', 'TB'); $i = 0
    while ($n -ge 1024 -and $i -lt $u.Count - 1) { $n = $n / 1024; $i++ }
    if ($i -le 1) { return ('{0:N0} {1}' -f $n, $u[$i]) }
    return ('{0:N1} {1}' -f $n, $u[$i])
}
function Format-Rate([double]$bps) { return ((Format-Bytes $bps) + '/s') }
function Format-Span([TimeSpan]$t) {
    if ($t.TotalDays -ge 1) { return ('{0} 天 {1} 小时' -f [int][Math]::Floor($t.TotalDays), $t.Hours) }
    if ($t.TotalHours -ge 1) { return ('{0} 小时 {1} 分' -f [int][Math]::Floor($t.TotalHours), $t.Minutes) }
    return ('{0} 分钟' -f [int][Math]::Max(0, [Math]::Floor($t.TotalMinutes)))
}
function From-Epoch($s) { try { if (-not $s) { return $null }; return [DateTimeOffset]::FromUnixTimeSeconds([long]$s).LocalDateTime } catch { return $null } }
function Format-Time([string]$iso, [string]$fmt = 'HH:mm:ss') {
    if (-not $iso) { return '' }
    try { return ([DateTime]::Parse($iso, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)).ToLocalTime().ToString($fmt) } catch { return '' }
}
function Get-StatusKey($st, [bool]$alive) {
    if (-not $st -or [string]$st.mode -eq 'OFF') { return 'off' }
    if (-not $alive) { return 'lost' }
    switch ([string]$st.mode) { 'OK' { return 'ok' } 'INIT' { return 'init' } default { if ($st.cutAll) { return 'cut' } else { return 'locked' } } }
}
'@
. ([scriptblock]::Create($HelperText))

# 模块：配置切换 / 订阅 / 内置引擎（界面线程只用其中的纯函数与路径）
$script:bpLoaded = $false; $script:bcLoaded = $false; $script:ModDir = $null
foreach ($dir in @($PSScriptRoot, (Join-Path $Root 'bin'))) {
    $c = Join-Path $dir 'BaiyangProfile.ps1'
    if (Test-Path -LiteralPath $c) {
        try { . $c; $script:bpLoaded = $true } catch {}
        $c2 = Join-Path $dir 'BuiltinCore.ps1'
        if ($script:bpLoaded -and (Test-Path -LiteralPath $c2)) { try { . $c2; $script:bcLoaded = $true } catch {} }
        if ($script:bpLoaded) { $script:ModDir = $dir; break }
    }
}

# 套件文件 → 安装位置（相对 C:\ProgramData\ClaudeGuard）
$UpdateMap = [ordered]@{
    'Config_Template\scripts\SecurityHub.ps1'          = 'bin\SecurityHub.ps1'
    'Config_Template\scripts\ClaudeHub.vbs'            = 'bin\ClaudeHub.vbs'
    'Config_Template\scripts\ClaudeGuard.ps1'          = 'bin\ClaudeGuard.ps1'
    'Config_Template\scripts\BaiyangProfile.ps1'       = 'bin\BaiyangProfile.ps1'
    'Config_Template\scripts\BuiltinCore.ps1'          = 'bin\BuiltinCore.ps1'
    'Config_Template\scripts\NetMonitor.ps1'           = 'bin\NetMonitor.ps1'
    'Config_Template\scripts\Refresh-Subscription.ps1' = 'bin\Refresh-Subscription.ps1'
    'Config_Template\profiles\sRYohxTjB2to.js'         = 'bin\strict-profile.js'
    'Config_Template\scripts\cg-guard.exe'             = 'bin\cg-guard.exe'
    'Config_Template\scripts\cg-hub.exe'               = 'bin\cg-hub.exe'
    'Config_Template\scripts\HubData.ps1'              = 'bin\HubData.ps1'
    'Resume-恢复保护.ps1'                               = 'bin\Resume.ps1'
    'Pause-关闭保护.ps1'                                = 'bin\Pause.ps1'
    'Rescue-恢复网络.ps1'                               = 'bin\Rescue.ps1'
    'Switch-热切换.ps1'                                 = 'bin\Switch.ps1'
    '回退-Claude保护版本.ps1'                           = 'rollback\Rollback.ps1'
}

# ================================================================= 后台采集线程（所有慢操作都在这里）
$CollectorText = @'
param($sync, $Root, $ModDir, $SettingsFile, $SuiteFile, $UpdateMap, $HelperText, $Gen)
$ErrorActionPreference = 'Continue'
. ([scriptblock]::Create($HelperText))
$bp = $false; $bc = $false
if ($ModDir) {
    try { . (Join-Path $ModDir 'BaiyangProfile.ps1'); $bp = $true } catch { $sync.err = 'BP: ' + $_.Exception.Message }
    if ($bp) { try { . (Join-Path $ModDir 'BuiltinCore.ps1'); $bc = $true } catch { $sync.err = 'BC: ' + $_.Exception.Message } }
}
$StateFile    = Join-Path $Root 'state\guard_state.json'
$ResultFile   = Join-Path $Root 'state\toggle-result.json'
$ProgressFile = Join-Path $Root 'state\switch-progress.json'
$EngineFile   = Join-Path $Root 'engine.json'
$PinFile      = Join-Path $Root 'pinned-node.json'
$LogFile      = Join-Path $Root 'logs\guard.log'
$SubResultFile = Join-Path (Split-Path $SettingsFile -Parent) 'sub-result.json'
$VersionsDir  = Join-Path $Root 'versions'
$CA = @{}; $TM = @{}

function Due([string]$k, [double]$sec) { $n = [DateTime]::UtcNow; if (-not $TM.ContainsKey($k) -or ($n - $TM[$k]).TotalSeconds -ge $sec) { $TM[$k] = $n; return $true }; return $false }
function MT([string]$f) { try { return [IO.File]::GetLastWriteTimeUtc($f).Ticks } catch { return 0L } }
function RJ([string]$f) { try { if ([IO.File]::Exists($f)) { return ([IO.File]::ReadAllText($f, [Text.Encoding]::UTF8) | ConvertFrom-Json) } } catch {}; return $null }
function CJ([string]$k, [string]$f) {
    # 按修改时间缓存的 JSON 读取；读失败（文件正被替换）时沿用上一次的内容
    $m = MT $f
    if (-not $CA.ContainsKey("$k#") -or $CA["$k#"] -ne $m) {
        if (-not [IO.File]::Exists($f)) { $CA[$k] = $null; $CA["$k#"] = $m }
        else { $v = RJ $f; if ($v) { $CA[$k] = $v; $CA["$k#"] = $m } }
    }
    return $CA[$k]
}
function NIC([string]$name) { try { foreach ($n in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) { if ($n.Name -eq $name) { return $n } } } catch {}; return $null }
function NicIPv4($n) { try { return (@($n.GetIPProperties().UnicastAddresses | Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $_.Address.ToString() }) -join ', ') } catch { return '-' } }
function Get-Mtu([string]$alias) {
    # IP 层 MTU 只能用 Get-NetIPInterface 读准（.NET 对 TUN 网卡报 65535，不真实）。
    # 但它走 WMI，网卡增删时可能卡住十几秒：所以放到独立线程里每 30 秒查一次全部网卡，采集线程只读缓存，永远不会被它拖住
    $j = $CA.mtuJob
    if ($j -and $j.h.IsCompleted) {
        $m = @{}
        try { foreach ($l in @($j.ps.EndInvoke($j.h))) { $kv = ([string]$l).Split([char]0x1F); if ($kv.Count -eq 2) { $m[$kv[0]] = $kv[1] } } } catch {}
        try { $j.ps.Dispose() } catch {}
        $CA.mtu = $m; $CA.mtuJob = $null; $j = $null
    } elseif ($j -and ((Get-Date) - $j.t).TotalSeconds -gt 60) {
        try { [void]$j.ps.BeginStop($null, $null) } catch {}
        $CA.mtuJob = $null; $j = $null
    }
    $miss = (-not $CA.mtu -or -not $CA.mtu.ContainsKey($alias))
    if (-not $j -and ((Due 'mtu' 30) -or ($miss -and (Due 'mtuMiss' 3)))) {
        $ps = [powershell]::Create()
        [void]$ps.AddScript('Get-NetIPInterface -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object { $_.InterfaceAlias + [char]0x1F + [string]$_.NlMtu }')
        $CA.mtuJob = @{ ps = $ps; h = $ps.BeginInvoke(); t = Get-Date }
    }
    if ($CA.mtu -and $CA.mtu.ContainsKey($alias)) { return [string]$CA.mtu[$alias] }
    return '读取中…'
}
function Get-RawApi([string]$path, [int]$ms, $es) {
    $req = [System.Net.HttpWebRequest]::Create(('http://127.0.0.1:{0}{1}' -f $es.apiPort, $path))
    $req.Method = 'GET'; $req.Proxy = $null; $req.Timeout = $ms; $req.ReadWriteTimeout = $ms
    if ($es.secret) { $req.Headers['Authorization'] = 'Bearer ' + $es.secret }
    $resp = $req.GetResponse()
    try { $sr = New-Object System.IO.StreamReader($resp.GetResponseStream()); $t = $sr.ReadToEnd(); $sr.Close() } finally { $resp.Close() }
    return $t
}

function Get-EngineSnap {
    $E = CJ 'eng' $EngineFile
    $set = CJ 'set' $SettingsFile
    $eng = $(if ($E -and [string]$E.engine -eq 'builtin') { 'builtin' } else { 'verge' })
    $es = [ordered]@{
        engine = $eng; netMode = $(if ($E -and [string]$E.netMode -eq 'sysproxy') { 'sysproxy' } else { 'tun' })
        source = $(if ($E -and [string]$E.subSource -eq 'local') { 'local' } else { 'baiyang' })
        mixedPort = $(if ($E -and $E.mixedPort) { [int]$E.mixedPort } else { 17897 }); apiPort = $(if ($E -and $E.apiPort) { [int]$E.apiPort } else { 19097 })
        secret = $(if ($E) { [string]$E.secret } else { '' }); builtin = ($eng -eq 'builtin')
    }
    $es.wantEngine  = $(if ($set -and [string]$set.pendingEngine) { [string]$set.pendingEngine } else { $es.engine })
    $es.wantNetMode = $(if ($set -and [string]$set.pendingNetMode) { [string]$set.pendingNetMode } else { $es.netMode })
    $es.wantSource  = $(if ($set -and [string]$set.pendingSource) { [string]$set.pendingSource } else { $es.source })
    $es.pinPending  = $(if ($set) { [string]$set.pinNode } else { '' })
    $es.configSwitch = $(if ($set -and $null -ne $set.configSwitch) { [bool]$set.configSwitch } else { $true })
    return $es
}

function Get-Speed($es) {
    $r = [ordered]@{ ok = $false; rate = $false; why = ''; down = 0.0; up = 0.0; total = 0.0; conns = -1 }
    $rx = 0.0; $tx = 0.0
    if ($es.builtin) {
        if (@([System.Diagnostics.Process]::GetProcessesByName('cg-mihomo')).Count -eq 0) { $r.why = '内置内核未运行'; $CA.bytes = $null; return $r }
        try { $t = Get-RawApi '/connections' 1200 $es } catch { $r.why = '控制接口无响应'; return $r }
        $rx = [double]([regex]::Match($t, '"downloadTotal":\s*(\d+)').Groups[1].Value)
        $tx = [double]([regex]::Match($t, '"uploadTotal":\s*(\d+)').Groups[1].Value)
        $r.conns = ([regex]::Matches($t, '"chains"')).Count
    } else {
        $n = NIC 'Mihomo'
        if (-not $n -or $n.OperationalStatus -ne 'Up') { $r.why = 'TUN 未运行'; $CA.bytes = $null; return $r }
        try { $s = $n.GetIPStatistics(); $rx = [double]$s.BytesReceived; $tx = [double]$s.BytesSent } catch { return $r }
    }
    $now = [DateTime]::UtcNow
    $r.ok = $true; $r.total = $rx + $tx
    if ($CA.bytes -and $CA.bytes.eng -eq $es.engine) {
        $dt = ($now - $CA.bytes.t).TotalSeconds
        if ($dt -gt 0.3) { $r.down = [Math]::Max(0, ($rx - $CA.bytes.rx) / $dt); $r.up = [Math]::Max(0, ($tx - $CA.bytes.tx) / $dt); $r.rate = $true }
    }
    $CA.bytes = @{ rx = $rx; tx = $tx; t = $now; eng = $es.engine }
    return $r
}

function Get-NodeDetail([string]$line, $m) {
    if ($line -match 'name:\s*([^,}]+)') { $m.node = $Matches[1].Trim() }
    if ($line -match 'type:\s*([^,}\s]+)') { $m.ntype = $Matches[1] }
    if ($line -match 'server:\s*([^,}\s]+)') { $m.server = $Matches[1] }
    if ($line -match 'port:\s*(\d+)') { $m.port = $Matches[1] }
    if ($line -match 'flow:\s*([^,}\s]+)') { $m.flow = $Matches[1] }
    $m.reality = ($line -match 'reality-opts')
}

function Get-SubData($es, $pin) {
    # 订阅信息 + 节点下拉框（只在订阅文件 / 来源 / 锁定节点变化时重新解析）
    if (-not $bp) { return $null }
    $builtinView = ($bc -and $es.wantEngine -eq 'builtin')
    $file = ''; $metaFile = ''; $profFile = ''; $vItem = $null; $vProfiles = $null
    if ($builtinView) { $file = Get-BCSubFile $es.wantSource; $metaFile = Get-BCSubMetaFile $es.wantSource }
    else {
        try {
            $d = Get-BPDataDir; $profFile = Join-Path $d 'profiles.yaml'
            $pk = 'prof:' + (MT $profFile)
            if ($CA.profKey -ne $pk) { $CA.prof = Get-BPProfiles $d; $CA.profKey = $pk; $CA.profDir = $d }
            $vProfiles = $CA.prof; $vItem = Get-BPBaiyangItem $vProfiles
            if ($vItem) { $file = Join-Path $d "profiles\$($vItem.File)" }
        } catch {}
    }
    $key = '{0}|{1}|{2}|{3}|{4}|{5}' -f $builtinView, $es.wantSource, (MT $file), (MT $metaFile), (MT $profFile), $pin.name
    if ($CA.subKey -eq $key) { return $CA.sub }
    $m = [ordered]@{ ok = $false; builtinView = $builtinView; source = $es.wantSource; nodes = @() }
    try {
        if ($builtinView) {
            $meta = Get-BCSubMeta $es.wantSource
            if (Test-Path -LiteralPath $file) {
                $m.ok = $true
                if ($es.wantSource -eq 'local') { $m.name = $(if ($meta) { [string]$meta.name } else { '本地配置' }); $m.host = '' }
                else {
                    $m.name = '白羊加速'; $m.host = $(if ($meta) { [string]$meta.host } else { '' })
                    foreach ($k in @('upload', 'download', 'total', 'expire')) { if ($meta -and $meta.$k) { $m[$k] = [double]$meta.$k } }
                }
                $text = Read-BPText $file
                $m.nodes = @(Get-BPNodeList $text)
                $m.nodeCount = $m.nodes.Count
                $line = Get-BPNodeLine $text $pin
                if ($line) { Get-NodeDetail $line $m }
                try { $m.fileTime = (Get-Item -LiteralPath $file).LastWriteTime } catch {}
            }
            $lm = Get-BCSubMeta 'local'
            $m.localName = $(if ($lm) { [string]$lm.name } else { '' })
        } elseif ($vItem) {
            $m.ok = $true
            $m.host = ([regex]::Match($vItem.Url, '^https?://([^/]+)')).Groups[1].Value
            for ($i = $vItem.Start; $i -le $vItem.End; $i++) {
                $l = $vProfiles.Lines[$i]
                if ($l -match '^  name:\s*(.+)$') { $m.name = $Matches[1].Trim() }
                elseif ($l -match '^    (upload|download|total|expire):\s*(\d+)') { $m[$Matches[1]] = [double]$Matches[2] }
                elseif ($l -match '^    update_interval:\s*(\d+)') { $m.interval = [int]$Matches[1] }
            }
            $text = Read-BPText $file
            $m.nodes = @(Get-BPNodeList $text)
            $m.nodeCount = $m.nodes.Count
            $line = Get-BPNodeLine $text $pin
            if ($line) { Get-NodeDetail $line $m }
            try { $m.fileTime = (Get-Item -LiteralPath $file).LastWriteTime } catch {}
        }
    } catch {}
    $CA.sub = [pscustomobject]$m; $CA.subKey = $key
    return $CA.sub
}

function Get-CoreVer($es) {
    if ($CA.coreVerEng -eq $es.engine -and $CA.coreVer) { return $CA.coreVer }
    $v = '-'
    try {
        if ($es.builtin -and $bc) { $x = Get-BCCoreVersion; if ($x) { $v = $x } }
        else {
            $exe = $null
            $cfg = Get-Content -LiteralPath (Join-Path $Root 'guard.config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($r in @(@($cfg.vergeCoreRoots) + @($cfg.coreRoots) | Where-Object { $_ })) { $x = Join-Path $r 'verge-mihomo.exe'; if (Test-Path -LiteralPath $x) { $exe = $x; break } }
            if ($exe) {
                $psi = New-Object System.Diagnostics.ProcessStartInfo($exe, '-v'); $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.CreateNoWindow = $true
                $p = [System.Diagnostics.Process]::Start($psi); $o = $p.StandardOutput.ReadToEnd(); [void]$p.WaitForExit(3000)
                if ($o -match '(v\d+\.\d+\.\d+)') { $v = $Matches[1] }
            }
        }
    } catch {}
    $CA.coreVer = $v; $CA.coreVerEng = $es.engine
    return $v
}

function Get-RuleVer {
    if ($CA.ruleVer) { return $CA.ruleVer }
    $v = '-'
    foreach ($f in @((Join-Path $Root 'bin\strict-profile.js'), (Join-Path $ModDir '..\profiles\sRYohxTjB2to.js'))) {
        try { if (Test-Path -LiteralPath $f) { $t = [IO.File]::ReadAllText($f); if ($t -match '严格版 (v\d+)') { $v = $Matches[1]; break } } } catch {}
    }
    $CA.ruleVer = $v; return $v
}

function Get-PhysKV {
    $kv = [ordered]@{}
    $p = $null
    try {
        foreach ($n in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            if ($n.OperationalStatus -ne 'Up' -or $n.Name -eq 'Mihomo' -or $n.Name -eq 'ClaudeGuard') { continue }
            if ($n.NetworkInterfaceType -notin @('Ethernet', 'Wireless80211', 'GigabitEthernet', 'Ppp')) { continue }
            if (@($n.GetIPProperties().GatewayAddresses | Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' }).Count -gt 0) { $p = $n; break }
        }
    } catch {}
    if ($p) {
        $props = $p.GetIPProperties()
        $kv['网卡'] = ('{0}（{1}）' -f $p.Name, $p.Description)
        $kv['本机 IP'] = NicIPv4 $p
        $kv['网关'] = (@($props.GatewayAddresses | Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $_.Address.ToString() }) -join ', ')
        $kv['DNS'] = (@($props.DnsAddresses | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $_.ToString() }) -join ', ')
        $kv['链路速率'] = $(if ($p.Speed -gt 0) { '{0:N0} Mbps' -f ($p.Speed / 1e6) } else { '-' })
        $kv['MTU'] = Get-Mtu $p.Name
    } else { $kv['网卡'] = '!未找到已连接的网卡' }
    return $kv
}

function Count-Runtime([string]$text) {
    $np = 0; $nr = 0; $sec = ''
    foreach ($l in ($text -split "`r?`n")) {
        if ($l -match '^([A-Za-z0-9_-]+):') { $sec = $Matches[1] }
        if ($sec -eq 'proxies' -and ($l -match '^\s*-\s+name:' -or $l -match '^\s*-\s*\{')) { $np++ }
        if ($sec -eq 'rules' -and $l -match '^\s*-\s+\S') { $nr++ }
    }
    return @($np, $nr)
}

function Get-NetData($es, $speed, $px, $conf) {
    # t / engine / netMode：界面据此判断数据是否新鲜、是否属于当前引擎（不是就显示“正在读取”，不展示过期内容）
    $d = [ordered]@{ t = (Get-Date); engine = $es.engine; netMode = $es.netMode; ms = 0 }
    $swNet = [Diagnostics.Stopwatch]::StartNew()
    if ($es.builtin -and $bc) {
        $d.titCore = '内置内核（cg-mihomo）'
        $kv = [ordered]@{}
        $core = @([System.Diagnostics.Process]::GetProcessesByName('cg-mihomo')) | Select-Object -First 1
        $kv['内核'] = $(if ($core) { $up = ''; try { $up = '，已运行 ' + (Format-Span ((Get-Date) - $core.StartTime)) } catch {}; "~运行中（PID $($core.Id)$up）" } else { '!未运行（保护关闭时内核不运行）' })
        $kv['内核版本'] = Get-CoreVer $es
        $kv['接管方式'] = $(if ($es.netMode -eq 'sysproxy') { '系统代理（127.0.0.1:{0}）' -f $es.mixedPort } else { 'TUN（网卡 ClaudeGuard）' })
        $kv['本地代理端口'] = ('127.0.0.1:{0}' -f $es.mixedPort)
        $kv['控制接口'] = ('127.0.0.1:{0}（带密钥）' -f $es.apiPort)
        if ($core) {
            try { $cf = (Get-RawApi '/configs' 1200 $es) | ConvertFrom-Json; $kv['代理模式'] = [string]$cf.mode } catch { $kv['控制接口'] = '!无响应' }
            if ($speed -and $speed.conns -ge 0) { $kv['当前连接'] = ('{0} 个' -f $speed.conns) }
        }
        $rt = Read-BPText $script:BC_Config
        $cnt = Count-Runtime $rt
        $kv['运行配置'] = $(if ($rt) { '{0} 个节点 · {1} 条规则' -f $cnt[0], $cnt[1] } else { '-' })
        try { $kv['配置生成于'] = (Get-Item -LiteralPath $script:BC_Config).LastWriteTime.ToString('MM-dd HH:mm:ss') } catch {}
        $kv['系统代理'] = $(if ($px.ours) { '~已指向内置内核' } elseif ($px.enabled) { '已开启：' + $px.server } else { '未开启' })
        $kv['其他 Clash'] = $(if (@($conf).Count -gt 0) { '!' + (@($conf | ForEach-Object { $_.name } | Select-Object -Unique) -join '、') } else { '~未运行' })
        $d.kvCore = $kv
        $d.titTun = 'TUN 隧道（ClaudeGuard）'
        $kv = [ordered]@{}
        $n = NIC 'ClaudeGuard'
        if ($es.netMode -eq 'sysproxy') { $kv['状态'] = '系统代理模式：不使用 TUN' }
        elseif ($n) {
            $kv['状态'] = $(if ($n.OperationalStatus -eq 'Up') { '~已连接' } else { '!' + $n.OperationalStatus })
            $kv['地址'] = NicIPv4 $n
            $kv['MTU'] = Get-Mtu 'ClaudeGuard'
            try { $s = $n.GetIPStatistics(); $kv['累计接收'] = Format-Bytes $s.BytesReceived; $kv['累计发送'] = Format-Bytes $s.BytesSent } catch {}
        } else { $kv['状态'] = '!不存在（保护未开启或内核未运行）' }
        $d.kvTun = $kv
    } else {
        $d.titCore = 'Clash Verge'
        $kv = [ordered]@{}
        $gui = Get-Process -Name 'clash-verge' -ErrorAction SilentlyContinue | Select-Object -First 1
        $core = Get-Process -Name 'verge-mihomo', 'verge-mihomo-alpha' -ErrorAction SilentlyContinue | Select-Object -First 1
        $kv['界面程序'] = $(if ($gui) { $up = ''; try { $up = '，已运行 ' + (Format-Span ((Get-Date) - $gui.StartTime)) } catch {}; "~运行中（PID $($gui.Id)$up）" } else { '!未运行' })
        $kv['内核'] = $(if ($core) { "~运行中（PID $($core.Id)）" } else { '!未运行' })
        $kv['内核版本'] = Get-CoreVer $es
        $svc = $null; try { $svc = Get-Service -Name 'clash_verge_service' -ErrorAction Stop } catch {}
        $kv['系统服务'] = $(if ($svc) { $(if ($svc.Status -eq 'Running') { '~运行中' } else { '!' + $svc.Status }) } else { '!未安装' })
        if ($bp) {
            try {
                $dd = Get-BPDataDir
                $c = Read-BPText (Join-Path $dd 'config.yaml')
                if ($c -match '(?m)^mode:\s*(\S+)') { $kv['代理模式'] = $Matches[1] }
                if ($c -match '(?m)^mixed-port:\s*(\d+)') { $kv['本地代理端口'] = '127.0.0.1:' + $Matches[1] }
                $rt = Read-BPText (Join-Path $dd 'clash-verge.yaml')
                $cnt = Count-Runtime $rt
                $kv['运行配置'] = ('{0} 个节点 · {1} 条规则' -f $cnt[0], $cnt[1])
                try { $kv['配置生成于'] = (Get-Item -LiteralPath (Join-Path $dd 'clash-verge.yaml')).LastWriteTime.ToString('MM-dd HH:mm:ss') } catch {}
            } catch {}
        }
        $d.kvCore = $kv
        $d.titTun = 'TUN 隧道（Mihomo）'
        $kv = [ordered]@{}
        $n = NIC 'Mihomo'
        if ($n) {
            $kv['状态'] = $(if ($n.OperationalStatus -eq 'Up') { '~已连接' } else { '!' + $n.OperationalStatus })
            $kv['地址'] = NicIPv4 $n
            $kv['MTU'] = Get-Mtu 'Mihomo'
            try { $s = $n.GetIPStatistics(); $kv['累计接收'] = Format-Bytes $s.BytesReceived; $kv['累计发送'] = Format-Bytes $s.BytesSent } catch {}
        } else { $kv['状态'] = '!不存在（Clash 未启动或 TUN 未开启）' }
        $d.kvTun = $kv
    }
    $d.kvPhys = Get-PhysKV
    $d.ms = [int]$swNet.ElapsedMilliseconds
    return $d
}

function Get-ClaudeKind($p) {
    $path = [string]$p.ExecutablePath
    if ($path -match 'AnthropicClaude') { return 'Claude 桌面版' }
    if ($path -match '\\claude-code\\' -or $path -match '\.local\\bin') { return 'Claude Code' }
    if ($path -match 'anthropic\.claude-code') { return 'Claude Code（VS Code）' }
    if ($p.Name -match '^(node|bun)') { return 'Claude Code（Node）' }
    return 'Claude'
}
function Get-Procs {
    $out = @()
    foreach ($p in @(Get-BPClaudeProcesses)) {
        $start = '-'; try { if ($p.CreationDate) { $start = ([datetime]$p.CreationDate).ToString('MM-dd HH:mm') } } catch {}
        $path = [string]$p.ExecutablePath
        $out += [pscustomobject]@{ kind = (Get-ClaudeKind $p); pid = [int]$p.ProcessId; mem = [double]$p.WorkingSetSize; start = $start; path = $(if ($path) { $path -replace [regex]::Escape($env:USERPROFILE), '~' } else { '-' }) }
    }
    return @($out | Sort-Object kind, pid)
}

function Read-LogItems {
    if (-not [IO.File]::Exists($LogFile)) { return $null }
    $fi = New-Object IO.FileInfo($LogFile)
    $stamp = '{0}-{1}' -f $fi.LastWriteTimeUtc.Ticks, $fi.Length
    if ($stamp -eq $CA.logStamp) { return $null }
    $fs = [System.IO.File]::Open($LogFile, 'Open', 'Read', 'ReadWrite')
    try {
        if ($fs.Length -gt 196608) { [void]$fs.Seek(-196608, 'End') }
        $sr = New-Object System.IO.StreamReader($fs, [Text.Encoding]::UTF8); $all = $sr.ReadToEnd()
    } finally { $fs.Close() }
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($l in ($all -split "`r?`n")) {
        $m = [regex]::Match($l, '^\[(\d{4})-(\d\d-\d\d) (\d\d:\d\d:\d\d)\] \[(\w+)\] (.*)$')
        if (-not $m.Success -or $m.Groups[4].Value -eq 'DRY') { continue }
        $msg = $m.Groups[5].Value -replace '【[^】]*】', '' -replace '=+', '' -replace '^\s+|\s+$', ''
        $msg = $msg -replace '^解除封锁：.*$', '已放行 Claude，连接正常' `
                    -replace '^进入封锁：', '已拦截 Claude：' `
                    -replace '^出口 IP：(\S+) \((\w+)\).*$', '出口 IP：$1（$2）' `
                    -replace '^ClaudeGuard [\d.]+ 启动.*$', '守护服务已启动' `
                    -replace '^加固完成$', '保护已开启' `
                    -replace '^应急恢复完成.*$', '保护已关闭，网络恢复普通直连' `
                    -replace '^出口探针失败（第 (\d+) 次，不影响放行）.*$', '出口检测超时（第 $1 次），不影响使用'
        if ($msg -match '^(开始加固|放行的内核|写入防火墙|同步防火墙|加固已应用|验证通过|应急恢复：|收到指令|允许：|移除不再需要)') { continue }
        if (-not $msg) { continue }
        $items.Add([pscustomobject]@{ d = $m.Groups[2].Value; t = $m.Groups[3].Value; lvl = $m.Groups[4].Value; msg = $msg })
    }
    $CA.logStamp = $stamp
    return $items.ToArray()
}

function Get-UpdateInfo {
    $suite = $null
    try { $s = (Get-Content -LiteralPath $SuiteFile -Raw -Encoding UTF8 | ConvertFrom-Json).path; if ($s -and (Test-Path -LiteralPath $s)) { $suite = [string]$s } } catch {}
    if (-not $suite) { return [pscustomobject]@{ suite = $null; changed = @() } }
    $changed = @()
    foreach ($k in $UpdateMap.Keys) {
        $src = Join-Path $suite $k; $dst = Join-Path $Root $UpdateMap[$k]
        $label = Split-Path $UpdateMap[$k] -Leaf
        if (-not (Test-Path -LiteralPath $src)) { continue }
        if (-not (Test-Path -LiteralPath $dst)) { $changed += $label; continue }
        try {
            if ($src -like '*.exe') {
                # 程序文件按大小 + 修改时间比较（不每次读整个文件算哈希）
                $fa = [IO.FileInfo]$src; $fb = [IO.FileInfo]$dst
                if ($fa.Length -ne $fb.Length -or $fa.LastWriteTimeUtc -gt $fb.LastWriteTimeUtc) { $changed += $label }
            } elseif ([IO.File]::ReadAllText($src, [Text.Encoding]::UTF8) -ne [IO.File]::ReadAllText($dst, [Text.Encoding]::UTF8)) { $changed += $label }
        } catch {}
    }
    return [pscustomobject]@{ suite = $suite; changed = $changed }
}

function Get-SavedVersions {
    if (-not (Test-Path -LiteralPath $VersionsDir)) { return @() }
    @(Get-ChildItem -LiteralPath $VersionsDir -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | ForEach-Object {
        $m = $null; try { $m = Get-Content -LiteralPath (Join-Path $_.FullName 'version.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
        [pscustomobject]@{ id = $_.Name; version = $(if ($m) { [string]$m.version } else { '?' }); ts = $(if ($m) { [string]$m.ts } else { '' }); note = $(if ($m) { [string]$m.note } else { '' }) }
    })
}

function Sync-Proxy([string]$key, $es, $prog, $px) {
    # 内置引擎的系统代理（当前用户设置）：
    #  · 热切换进行中 → 按切换脚本的指示（bridge = 指向内置内核；clear = 关掉指向内置内核的代理）
    #  · 系统代理模式 + 保护开启 → 保持指向内置内核；保护关闭 → 关掉
    #  · TUN 模式：Clash Verge 退出后留下的 127.0.0.1 代理已失效 → 关掉
    if (-not $bc -or $sync.selfTest) { return }
    try {
        if ($prog -and $prog.live) {
            if ($prog.sysproxy -eq 'bridge' -and -not $px.ours) { Set-BCSysProxy $true }
            elseif ($prog.sysproxy -eq 'clear' -and $px.ours) { Set-BCSysProxy $false }
            return
        }
        if ($sync.busy) { return }
        $on = ($key -ne 'off' -and $key -ne 'lost')
        if ($es.builtin -and $es.netMode -eq 'sysproxy' -and $on) {
            if (-not $px.ours) { Set-BCSysProxy $true; [void]$sync.notices.Add(@('系统代理已开启', ('已指向内置内核 127.0.0.1:{0}。' -f $es.mixedPort), 'Info')) }
            return
        }
        if ($px.ours) { Set-BCSysProxy $false; return }
        if ($es.builtin -and $on -and $px.enabled -and $px.server -match '^(http=)?127\.0\.0\.1:\d+$' -and @(Get-Process -Name 'clash-verge', 'verge-mihomo' -ErrorAction SilentlyContinue).Count -eq 0) {
            Set-BCSysProxy $false
            [void]$sync.notices.Add(@('已关闭失效的系统代理', ('{0} 是 Clash Verge 留下的，它已退出；内置引擎用 TUN 接管，不需要系统代理。' -f $px.server), 'Info'))
        }
    } catch {}
}

function Get-Snapshot {
    $s = @{ t = Get-Date; bp = $bp; bc = $bc }
    $st = $CA.st
    $m = MT $StateFile
    if ($m -ne $CA.stMt) {
        $v = RJ $StateFile
        if ($v) {
            $CA.st = $v; $CA.stMt = $m; $st = $v
            try { $CA.stSig = ($v | Select-Object * -ExcludeProperty ts, cfgStamp | ConvertTo-Json -Depth 6 -Compress) } catch { $CA.stSig = [string]$m }
        }
    }
    $s.stSig = [string]$CA.stSig
    $alive = $false
    if ($st -and [string]$st.mode -ne 'OFF') { try { $ts = [DateTime]::Parse([string]$st.ts, $null, [System.Globalization.DateTimeStyles]::RoundtripKind); $alive = ((([DateTime]::UtcNow) - $ts.ToUniversalTime()).TotalSeconds -le 15) } catch {} }
    $s.st = $st; $s.alive = $alive; $s.key = Get-StatusKey $st $alive
    $s.toggle = CJ 'toggle' $ResultFile
    $s.subRes = CJ 'subres' $SubResultFile
    $pg = CJ 'prog' $ProgressFile
    if ($pg) {
        $live = $false
        try { $live = (-not $pg.done) -and (((Get-Date) - [DateTime]::Parse([string]$pg.ts)).TotalSeconds -lt 180) } catch {}
        $pg | Add-Member -NotePropertyName live -NotePropertyValue $live -Force
    }
    $s.progress = $pg
    $es = Get-EngineSnap
    $s.es = $es
    if ($bp) {
        $pm = MT $PinFile
        if ($CA.pinMt -ne $pm -or -not $CA.pin) { $p = Get-BPPinnedNode; $cn = Get-BPCountryName $p.country; if (-not $cn) { $cn = $p.country }; $CA.pin = [pscustomobject]@{ name = $p.name; country = $p.country; cname = $cn; since = $p.since; fuzzy = $p.fuzzy }; $CA.pinMt = $pm }
        $s.pin = $CA.pin
    } else { $s.pin = [pscustomobject]@{ name = 'V3-【双ISP家庭网络】韩国'; country = 'KR'; cname = '韩国'; since = '' } }

    $px = [pscustomobject]@{ enabled = $false; server = ''; ours = $false }
    if ($bc) { $p = Get-BCSysProxy; $px = [pscustomobject]@{ enabled = $p.enabled; server = $p.server; ours = ($p.enabled -and $p.server -match ('^(http=)?127\.0\.0\.1:{0}$' -f $es.mixedPort)) } }
    $s.px = $px
    Sync-Proxy $s.key $es $pg $px

    if ($bc -and ($es.builtin -or $es.wantEngine -eq 'builtin')) {
        if ((Due 'conf' 3) -or -not $CA.ContainsKey('conf')) { $CA.conf = @(Get-BCConflicts | ForEach-Object { [pscustomobject]@{ kind = $_.kind; name = $_.name } }) }
    } else { $CA.conf = @() }
    $s.conf = $CA.conf
    if ($bp -and ((Due 'vmode' 5) -or -not $CA.ContainsKey('vmode'))) { $CA.vmode = Get-BPConfigMode }
    $s.vmode = $CA.vmode

    $vis = [bool]$sync.visible -or [bool]$sync.selfTest
    $page = [string]$sync.page
    if ($vis -and ($page -in @('overview', 'network') -or $sync.selfTest)) { $CA.speed = Get-Speed $es }
    $s.speed = $CA.speed
    if ($bp -and ((Due 'sub' 3) -or -not $CA.ContainsKey('sub'))) { [void](Get-SubData $es $CA.pin) }
    $s.sub = $CA.sub
    $netStale = ($CA.net -and ([string]$CA.net.engine -ne [string]$es.engine -or [string]$CA.net.netMode -ne [string]$es.netMode))
    if ($vis -and ($page -eq 'network' -or $sync.selfTest) -and ((Due 'net' 2) -or $sync.forceNet -or $netStale)) {
        $sync.forceNet = $false
        $CA.net = Get-NetData $es $CA.speed $px $CA.conf
    }
    $s.net = $CA.net
    if ($bp -and $vis -and ($page -eq 'procs' -or $sync.selfTest) -and ((Due 'procs' 4) -or $sync.forceProcs)) { $sync.forceProcs = $false; $CA.procs = Get-Procs }
    $s.procs = $CA.procs
    if ($vis -or (Due 'logsHidden' 10)) {
        try { $li = Read-LogItems; if ($null -ne $li) { $CA.logs = $li; $CA.logSeq = [int]$CA.logSeq + 1 } } catch {}
    }
    $s.logs = $CA.logs; $s.logSeq = [int]$CA.logSeq
    if ((Due 'upd' $(if ($vis) { 60 } else { 300 })) -or $sync.reqUpdate) { $sync.reqUpdate = $false; $CA.upd = Get-UpdateInfo; $CA.vers = @(Get-SavedVersions) }
    $s.update = $CA.upd; $s.versions = $CA.vers
    if ($vis -and ($page -eq 'maint' -or $sync.selfTest)) { $s.coreVer = Get-CoreVer $es; $s.ruleVer = Get-RuleVer }
    else { $s.coreVer = $CA.coreVer; $s.ruleVer = $CA.ruleVer }
    return $s
}

# $Gen：本采集线程的代号。界面发现采集卡住时会另起一个新线程（代号 +1），旧线程醒来后发现代号不符就退出，不会写入过期数据
while (-not $sync.stop -and $sync.gen -eq $Gen) {
    try { $snap = Get-Snapshot; if ($sync.gen -ne $Gen) { break }; $sync.snap = $snap; $sync.seq = [int]$sync.seq + 1; $sync.beat = [DateTime]::UtcNow } catch { $sync.err = $_.Exception.Message }
    $wait = $(if ($sync.busy -or ($sync.snap -and $sync.snap.progress -and $sync.snap.progress.live)) { 5 } elseif ($sync.visible) { 10 } else { 25 })
    for ($i = 0; $i -lt $wait -and -not $sync.wake -and -not $sync.stop -and $sync.gen -eq $Gen; $i++) { Start-Sleep -Milliseconds 100 }
    $sync.wake = $false
}
'@

$sync = [hashtable]::Synchronized(@{ page = 'overview'; visible = $false; busy = $false; snap = $null; seq = 0; stop = $false; wake = $false; gen = 0; beat = [DateTime]::UtcNow
    reqUpdate = $false; forceNet = $false; forceProcs = $false; selfTest = [bool]$SelfTest; err = ''
    notices = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList)) })
function Start-Collector {
    $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'MTA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    $sync.gen = [int]$sync.gen + 1; $sync.beat = [DateTime]::UtcNow
    [void]$ps.AddScript($CollectorText).AddArgument($sync).AddArgument($Root).AddArgument($script:ModDir).AddArgument($SettingsFile).AddArgument($SuiteFile).AddArgument($UpdateMap).AddArgument($HelperText).AddArgument([int]$sync.gen)
    $script:collector = @{ ps = $ps; rs = $rs; handle = $ps.BeginInvoke(); started = Get-Date }
}
function Stop-Collector {
    $sync.stop = $true
    try { if ($script:collector) { [void]$script:collector.handle.AsyncWaitHandle.WaitOne(1500); $script:collector.ps.Dispose(); $script:collector.rs.Dispose() } } catch {}
}

# ================================================================= 显示辅助
function New-Tb([string]$text, [string]$color, [double]$size = 13) {
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $text; $t.Foreground = B $color; $t.FontSize = $size; $t.TextWrapping = 'Wrap'
    return $t
}

function Set-KV($panel, $pairs, [int]$labelWidth = 120) {
    # pairs：有序哈希表 标签→值；值以 '!' 开头 = 红色，'~' 开头 = 绿色。内容没变就不重建
    if (-not $pairs) { return }
    $sig = ($pairs | ConvertTo-Json -Compress)
    if ($panel.Tag -eq $sig) { return }
    $panel.Tag = $sig
    $panel.Children.Clear()
    foreach ($k in $pairs.Keys) {
        $v = [string]$pairs[$k]; $color = '#0F172A'
        if ($v.StartsWith('!')) { $v = $v.Substring(1); $color = '#DC2626' } elseif ($v.StartsWith('~')) { $v = $v.Substring(1); $color = '#15803D' }
        $g = New-Object System.Windows.Controls.Grid
        $g.Margin = New-Object System.Windows.Thickness(0, 4, 0, 4)
        $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = New-Object System.Windows.GridLength($labelWidth)
        $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
        [void]$g.ColumnDefinitions.Add($c1); [void]$g.ColumnDefinitions.Add($c2)
        $l = New-Tb ([string]$k) '#64748B' 13
        $r = New-Tb $v $color 13
        [System.Windows.Controls.Grid]::SetColumn($r, 1)
        [void]$g.Children.Add($l); [void]$g.Children.Add($r)
        [void]$panel.Children.Add($g)
    }
}

function Add-Row($panel, [string]$state, [string]$title, [string]$detail) {
    $color = switch ($state) { 'ok' { '#16A34A' } 'bad' { '#DC2626' } default { '#D97706' } }
    $glyph = switch ($state) { 'ok' { [string][char]0xE73E } 'bad' { [string][char]0xE711 } default { [string][char]0xE7BA } }
    $g = New-Object System.Windows.Controls.Grid
    $g.Margin = New-Object System.Windows.Thickness(0, 5, 0, 5)
    $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = New-Object System.Windows.GridLength(28)
    $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
    [void]$g.ColumnDefinitions.Add($c1); [void]$g.ColumnDefinitions.Add($c2)
    $ic = New-Tb $glyph $color 13; $ic.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe MDL2 Assets'); $ic.Margin = New-Object System.Windows.Thickness(0, 2, 0, 0)
    $sp = New-Object System.Windows.Controls.StackPanel
    [void]$sp.Children.Add((New-Tb $title '#0F172A' 13))
    if ($detail) { $d = New-Tb $detail '#64748B' 12; $d.Margin = New-Object System.Windows.Thickness(0, 2, 0, 0); [void]$sp.Children.Add($d) }
    [System.Windows.Controls.Grid]::SetColumn($sp, 1)
    [void]$g.Children.Add($ic); [void]$g.Children.Add($sp)
    [void]$panel.Children.Add($g)
}

function Add-TableRow($panel, [string[]]$cells, [double[]]$widths, [bool]$header = $false, [string[]]$colors = $null) {
    $g = New-Object System.Windows.Controls.Grid
    $g.Margin = New-Object System.Windows.Thickness(0, $(if ($header) { 0 } else { 4 }), 0, 4)
    for ($i = 0; $i -lt $cells.Count; $i++) {
        $cd = New-Object System.Windows.Controls.ColumnDefinition
        $cd.Width = $(if ($widths[$i] -gt 0) { New-Object System.Windows.GridLength($widths[$i]) } else { New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star) })
        [void]$g.ColumnDefinitions.Add($cd)
        $col = $(if ($header) { '#64748B' } elseif ($colors -and $colors[$i]) { $colors[$i] } else { '#0F172A' })
        $t = New-Tb $cells[$i] $col $(if ($header) { 12 } else { 13 })
        $t.TextWrapping = 'NoWrap'; $t.TextTrimming = 'CharacterEllipsis'; $t.Margin = New-Object System.Windows.Thickness(0, 0, 10, 0)
        [System.Windows.Controls.Grid]::SetColumn($t, $i)
        [void]$g.Children.Add($t)
    }
    [void]$panel.Children.Add($g)
    if ($header) {
        $sep = New-Object System.Windows.Controls.Border; $sep.Height = 1; $sep.Background = B '#E2E8F0'; $sep.Margin = New-Object System.Windows.Thickness(0, 2, 0, 2)
        [void]$panel.Children.Add($sep)
    }
}

# ================================================================= 设置（控制台自己的，每个用户一份）
$script:settingsCache = $null
function Get-Settings {
    if ($script:settingsCache) { return $script:settingsCache }
    $o = $null
    try { if (Test-Path -LiteralPath $SettingsFile) { $o = Get-Content -LiteralPath $SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json } } catch {}
    $h = [ordered]@{ firstRunDone = $false; configSwitch = $true }
    if ($o) { foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = $p.Value } }
    $script:settingsCache = $h
    return $h
}
function Save-Setting([string]$Name, $Value) {
    try {
        New-Item -ItemType Directory -Path $SettingsDir -Force | Out-Null
        $h = Get-Settings; $h[$Name] = $Value
        [IO.File]::WriteAllText($SettingsFile, ($h | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
    } catch {}
    $script:settingsCache = $null
    $sync.wake = $true
}
function Get-ConfigMode { if ([bool](Get-Settings).configSwitch) { 'Strict' } else { 'Keep' } }

# ================================================================= 状态模型
$Palette = @{
    ok     = @{ color = '#16A34A'; soft = '#DCFCE7'; glyph = [string][char]0xEA18 }
    init   = @{ color = '#2563EB'; soft = '#DBEAFE'; glyph = [string][char]0xE895 }
    locked = @{ color = '#DC2626'; soft = '#FEE2E2'; glyph = [string][char]0xE72E }
    cut    = @{ color = '#DC2626'; soft = '#FEE2E2'; glyph = [string][char]0xE72E }
    lost   = @{ color = '#D97706'; soft = '#FEF3C7'; glyph = [string][char]0xE7BA }
    off    = @{ color = '#94A3B8'; soft = '#F1F5F9'; glyph = [string][char]0xE785 }
}
$ModeInfo = [ordered]@{
    tun   = @{ engine = 'builtin'; netMode = 'tun';      label = '内置 · TUN' }
    sys   = @{ engine = 'builtin'; netMode = 'sysproxy'; label = '内置 · 系统代理' }
    verge = @{ engine = 'verge';   netMode = 'tun';      label = 'Clash Verge' }
}
function Get-ModeKey([string]$engine, [string]$netMode) { if ($engine -eq 'builtin') { if ($netMode -eq 'sysproxy') { return 'sys' } return 'tun' } return 'verge' }

function Get-Status($s) {
    $st = $s.st; $cname = $s.pin.cname
    switch ($s.key) {
        'off'  { return [pscustomobject]@{ key = 'off'; title = '保护已关闭'; short = '未保护'; sub = '现在是普通网络，Claude 未受保护。需要使用 Claude 时点「开启保护」。' } }
        'lost' { return [pscustomobject]@{ key = 'lost'; title = '守护服务未响应'; short = '守护未响应'; sub = '超过 15 秒没有收到守护服务的状态。系统会在 1 分钟内自动重启它；如果一直这样，请点「开启保护」重新启用。' } }
        'ok'   {
            $sub = ('Claude 正在通过锁定的{0}节点安全连接，网络异常时会自动断开，不会回落直连。' -f $cname)
            if ($st.switching) { $sub = ('正在热切换（{0}），保护保持开启。' -f $st.switching.target) }
            return [pscustomobject]@{ key = 'ok'; title = '保护中'; short = '保护中'; sub = $sub }
        }
        'init' { return [pscustomobject]@{ key = 'init'; title = '正在启动保护'; short = '启动中'; sub = [string]$st.reason } }
        'cut'  { return [pscustomobject]@{ key = 'cut'; title = '已断网保护'; short = '已断网'; sub = ('整机已断网以防泄露。原因：{0}' -f $st.reason) } }
        default { return [pscustomobject]@{ key = 'locked'; title = '已拦截 Claude 连接'; short = '已拦截'; sub = ('Claude 暂时无法联网，异常恢复后会自动放行。原因：{0}' -f $st.reason) } }
    }
}
function Get-Check($state, [string]$id) { foreach ($c in @($state.checks)) { if ($c.id -eq $id) { return $c } }; return $null }
function Chk-Ok($state, [string]$id) { $c = Get-Check $state $id; return [bool]($c -and $c.ok) }
function Test-On { return ($script:status -and $script:status.key -ne 'off') }

$script:snap = $null
$script:status = $null
$script:prevKey = ''
$script:prevIp = ''
$script:busy = $null
$script:lastViewSig = ''
$script:lastLogSeq = -1
$script:subBusy = $null
$script:lastAutoSub = [DateTime]::MinValue
$script:latHist = New-Object System.Collections.Generic.List[double]
$script:lastIdTime = ''
$script:testJob = $null
$script:bgJobs = @()
$script:lastSeq = -1
$script:lastSeqAt = Get-Date

# ================================================================= 渲染：状态 / 概览
function Update-View($s) {
    $st = $s.st
    $stat = Get-Status $s
    $script:status = $stat
    $p = $Palette[$stat.key]
    $dot.Background = B $p.color; $dotGlyph.Text = $p.glyph
    $statusTitle.Text = $stat.title; $statusSub.Text = $stat.sub
    $sideDot.Fill = B $p.color; $sideStatus.Text = $stat.short
    $hdrDot.Fill = B $p.color; $hdrStatus.Text = $stat.short; $hdrStatus.Foreground = B $p.color; $hdrChip.Background = B $p.soft
    $modeLbl = $ModeInfo[(Get-ModeKey $s.es.engine $s.es.netMode)].label
    $hdrMode.Text = '· ' + $modeLbl
    $sideMode.Text = $modeLbl

    $on = ($stat.key -ne 'off')
    $btnMain.IsEnabled = -not $script:busy
    if ($on) { $btnMain.Content = '关闭保护'; $btnMain.Background = B '#FFFFFF'; $btnMain.Foreground = B '#DC2626'; $btnMain.BorderBrush = B '#FECACA' }
    else     { $btnMain.Content = '开启保护'; $btnMain.Background = B '#2563EB'; $btnMain.Foreground = B '#FFFFFF'; $btnMain.BorderBrush = B '#2563EB' }
    $btnProbe.IsEnabled = ($on -and -not $script:probeAsk)
    $forced = [bool]($st -and $st.forced)
    $btnForce.Content = $(if ($forced) { '取消强制断网' } else { '强制断网' })
    $btnForce.IsEnabled = $on

    $panelLeak.Children.Clear(); $panelLeak2.Children.Clear(); $panelChecks.Children.Clear()
    $id = $(if ($st) { $st.identity } else { $null })
    if ($on -and $id -and $id.ok) {
        $tIp.Text = [string]$id.ip
        $region = [string]$id.country; if ($script:bpLoaded) { $cn = Get-BPCountryName $region; if ($cn) { $region = $cn } }
        $tIpSub.Text = ('{0} · AS{1}' -f $region, $id.asn)
        $sideIp.Text = ('{0} · {1}' -f $id.ip, $id.country)
        $tLat.Text = ('{0:N0} ms' -f [double]$id.ms)
        $fs = 0; try { $fs = [int]$st.probe.failStreak } catch {}
        $tLatSub.Text = $(if ($fs -gt 0) { '最近 {0} 次检测失败' -f $fs } else { '上次 ' + (Format-Time ([string]$id.time) 'HH:mm') })
        $tLatSub.Foreground = B $(if ($fs -gt 0) { '#B45309' } else { '#64748B' })
        if ([string]$id.time -ne $script:lastIdTime) {
            $script:lastIdTime = [string]$id.time
            $script:latHist.Add([double]$id.ms); while ($script:latHist.Count -gt 24) { $script:latHist.RemoveAt(0) }
        }
    } elseif ($on) {
        $tIp.Text = '检测中…'; $tIpSub.Text = '-'; $tLat.Text = '-'; $tLatSub.Text = '尚未完成首次检测'; $sideIp.Text = ''
    } else {
        $tIp.Text = '-'; $tIpSub.Text = '保护未开启'; $tLat.Text = '-'; $tLatSub.Text = '-'; $sideIp.Text = '普通网络'
    }
    Update-Spark

    if (-not $on) {
        $checkSummary.Text = ''; $checkSummary2.Text = ''
        Add-Row $panelLeak 'warn' '保护未开启' '当前为普通网络，防护均未生效。'
        Add-Row $panelLeak2 'warn' '保护未开启' '当前为普通网络，防护均未生效。'
        return
    }
    $pin = Chk-Ok $st 'pin'; $modeOk = Chk-Ok $st 'mode'; $strict = Chk-Ok $st 'strict'
    $fwdef = Chk-Ok $st 'fwdef'; $fwrules = Chk-Ok $st 'fwrules'; $tun = Chk-Ok $st 'tun'; $route = Chk-Ok $st 'route'
    $v6 = Chk-Ok $st 'ipv6'
    $kr = [bool]($id -and $id.ok -and $id.country -eq [string]$st.expected.country)
    $prot = @(
        @(('出口固定在' + $s.pin.cname), ($pin -and ($kr -or -not ($id -and $id.ok))), ('只使用锁定的节点（{0}），不会切换到其他节点或地区' -f $s.pin.name), '节点配置或出口地区异常'),
        @('DNS 不外泄', ($strict -and $fwrules -and $fwdef), '域名解析经节点加密完成，运营商看不到', '解析防护缺失，可能外泄'),
        @('IPv6 已封锁', ($fwrules -and $v6 -and $modeOk), '不会通过 IPv6 绕过节点', '存在可用的公网 IPv6'),
        @('断网不回落直连', ($fwdef -and $fwrules -and $route -and $tun), '节点或内核断开时直接断网，不会走本地网络', '防火墙或路由存在缺口')
    )
    foreach ($x in $prot) {
        foreach ($pnl in @($panelLeak, $panelLeak2)) { if ($x[1]) { Add-Row $pnl 'ok' $x[0] $x[2] } else { Add-Row $pnl 'bad' $x[0] $x[3] } }
    }
    $all = @($st.checks)
    $bad = @($all | Where-Object { -not $_.ok -and $_.level -eq 'hard' }).Count
    $warnN = @($all | Where-Object { -not $_.ok -and $_.level -ne 'hard' }).Count
    foreach ($cs in @($checkSummary, $checkSummary2)) {
        if ($bad -eq 0 -and $warnN -eq 0) { $cs.Text = ('{0} 项检查全部正常' -f $all.Count); $cs.Foreground = B '#16A34A' }
        elseif ($bad -eq 0) { $cs.Text = ('{0} 项提示' -f $warnN); $cs.Foreground = B '#D97706' }
        else { $cs.Text = ('{0} 项异常' -f $bad); $cs.Foreground = B '#DC2626' }
    }
    foreach ($c in $all) {
        $st2 = $(if ($c.ok) { 'ok' } elseif ($c.level -eq 'hard') { 'bad' } else { 'warn' })
        $lvl = $(if ($c.level -eq 'hard') { '硬性' } else { '提示' })
        Add-Row $panelChecks $st2 ('{0}　[{1}]' -f $c.title, $lvl) ([string]$c.detail)
    }
}

function Update-Spark {
    $pts = New-Object System.Windows.Media.PointCollection
    $n = $script:latHist.Count
    if ($n -ge 2) {
        $max = ($script:latHist | Measure-Object -Maximum).Maximum; $min = ($script:latHist | Measure-Object -Minimum).Minimum
        $rng = [Math]::Max(1, $max - $min)
        for ($i = 0; $i -lt $n; $i++) { $pts.Add((New-Object System.Windows.Point((70.0 * $i / ($n - 1)), (24 - 22.0 * ($script:latHist[$i] - $min) / $rng)))) }
    }
    $sparkLine.Points = $pts
}

function Update-Busy($s) {
    if (-not $script:busy) { $busyBox.Visibility = 'Collapsed'; return }
    $busyBox.Visibility = 'Visible'
    $t = switch ($script:busy.target) { 'on' { '正在开启保护：拉取订阅、生成严格配置、启动内核…' } 'off' { '正在关闭保护…' } default { '正在热切换：' + $script:busy.label } }
    $pg = $s.progress
    if ($script:busy.target -eq 'switch' -and $pg -and $pg.live) {
        try { if ([DateTime]::Parse([string]$pg.ts) -ge $script:busy.started.AddSeconds(-2)) { $t = ('第 {0}/{1} 步 · {2}' -f $pg.step, $pg.total, $pg.text) } } catch {}
    }
    $el = [int]((Get-Date) - $script:busy.started).TotalSeconds
    $busyText.Text = ('{0}（{1} 秒）' -f $t, $el)
}

function Update-Tiles($s) {
    $sp = $s.speed
    if (-not $sp) { $tSpeed.Text = '-'; $tSpeedSub.Text = '-' }
    elseif (-not $sp.ok) { $tSpeed.Text = '-'; $tSpeedSub.Text = [string]$sp.why }
    elseif (-not $sp.rate) { $tSpeed.Text = '计算中…'; $tSpeedSub.Text = ('累计 {0}' -f (Format-Bytes $sp.total)) }
    else {
        $tSpeed.Text = ('↓ {0}' -f (Format-Rate $sp.down))
        $tSpeedSub.Text = ('↑ {0}　累计 {1}{2}' -f (Format-Rate $sp.up), (Format-Bytes $sp.total), $(if ($sp.conns -ge 0) { '　{0} 连接' -f $sp.conns } else { '' }))
    }
    $m = $s.sub
    if ($m -and $m.ok -and $m.total) {
        $used = [double]$m.upload + [double]$m.download
        $tQuota.Text = (Format-Bytes $used)
        $exp = From-Epoch $m.expire
        $tQuotaSub.Text = $(if ($exp) { '共 {0} · {1} 到期' -f (Format-Bytes $m.total), $exp.ToString('yyyy-MM-dd') } else { '共 ' + (Format-Bytes $m.total) })
    } else { $tQuota.Text = '-'; $tQuotaSub.Text = $(if ($m -and $m.ok -and $m.source -eq 'local') { '本地配置无流量信息' } else { '未读取到订阅信息' }) }
}

function Update-OverviewKV($s) {
    $m = $s.sub; $es = $s.es
    $kv = [ordered]@{}
    $kv['运行模式'] = $ModeInfo[(Get-ModeKey $es.engine $es.netMode)].label
    $kv['锁定节点'] = $s.pin.name
    if ($m -and $m.ok) {
        $kv['协议'] = $(if ($m.ntype) { ('{0}{1}{2}' -f $m.ntype.ToUpper(), $(if ($m.reality) { ' + Reality' } else { '' }), $(if ($m.flow) { ' · ' + $m.flow } else { '' })) } else { '-' })
        $kv['中继入口'] = $(if ($m.server) { '{0} : {1}' -f $m.server, $m.port } else { '!订阅里没有锁定的节点' })
    }
    if ($es.builtin) {
        $kv['节点来源'] = $(if ($es.source -eq 'local') { '导入的本地配置' } else { '白羊订阅' })
        $kv['规则'] = '内置严格规则（仅锁定节点 · 零回落直连）'
        if (@($s.conf).Count -gt 0) { $kv['冲突软件'] = '!' + (@($s.conf | ForEach-Object { $_.name } | Select-Object -Unique) -join '、') + ' 在运行' }
    } else {
        $kv['Clash 配置'] = switch ([string]$s.vmode) { 'strict' { '~严格配置（仅锁定节点）' } 'original' { '白羊原始配置（全部节点）' } default { '未识别' } }
    }
    Set-KV $kvNode $kv 90
}

function Update-Events($s) {
    if ($s.logSeq -eq $script:lastLogSeq) { return }
    $script:lastLogSeq = $s.logSeq
    $panelEvents.Children.Clear()
    $last = @(@($s.logs) | Select-Object -Last 6); [array]::Reverse($last)
    if ($last.Count -eq 0) { [void]$panelEvents.Children.Add((New-Tb '暂无事件' '#94A3B8' 12)) }
    foreach ($e in $last) { Add-EventRow $panelEvents $e $false }
    if ($script:page -eq 'logs') { Update-LogPage }
}

function Add-EventRow($panel, $e, [bool]$withSec) {
    $g = New-Object System.Windows.Controls.Grid
    $g.Margin = New-Object System.Windows.Thickness(0, 3, 0, 3)
    $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = New-Object System.Windows.GridLength($(if ($withSec) { 130 } else { 96 }))
    $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
    [void]$g.ColumnDefinitions.Add($c1); [void]$g.ColumnDefinitions.Add($c2)
    $time = $(if ($withSec) { '{0} {1}' -f $e.d, $e.t } else { '{0} {1}' -f $e.d, $e.t.Substring(0, 5) })
    $t1 = New-Tb $time '#94A3B8' 12
    $warn = ($e.lvl -eq 'WARN' -or $e.lvl -eq 'ERROR')
    $t2 = New-Tb $e.msg $(if ($e.lvl -eq 'ERROR') { '#DC2626' } elseif ($warn) { '#B45309' } else { '#334155' }) 12.5
    [System.Windows.Controls.Grid]::SetColumn($t2, 1)
    [void]$g.Children.Add($t1); [void]$g.Children.Add($t2)
    [void]$panel.Children.Add($g)
}

function Update-LogPage {
    $panelAllEvents.Children.Clear()
    $src = @(@($script:snap.logs))
    if ($chkWarnOnly.IsChecked) { $src = @($src | Where-Object { $_.lvl -eq 'WARN' -or $_.lvl -eq 'ERROR' }) }
    $last = @($src | Select-Object -Last 150); [array]::Reverse($last)
    if ($last.Count -eq 0) { [void]$panelAllEvents.Children.Add((New-Tb '暂无事件' '#94A3B8' 12)); return }
    foreach ($e in $last) { Add-EventRow $panelAllEvents $e $true }
}

# ================================================================= 运行模式（概览 + 引擎与节点 两组卡片）
$script:fillingMode = $false
function Update-Modes($s) {
    $es = $s.es
    $on = Test-On
    $cur = Get-ModeKey $es.engine $es.netMode
    $want = Get-ModeKey $es.wantEngine $es.wantNetMode
    $sel = $(if ($on) { $cur } else { $want })
    $script:fillingMode = $true
    foreach ($pair in @(@('tun', $mTun, $cTun, $mTunState, $cTunState), @('sys', $mSys, $cSys, $mSysState, $cSysState), @('verge', $mVerge, $cVerge, $mVergeState, $cVergeState))) {
        $k = $pair[0]
        $pair[1].IsChecked = ($k -eq $sel); $pair[2].IsChecked = ($k -eq $sel)
        $txt = ''; $col = '#64748B'
        if ($on -and $k -eq $cur) { $txt = '● 正在使用'; $col = '#16A34A' }
        elseif (-not $on -and $k -eq $want -and $want -ne $cur) { $txt = '下次开启保护时生效'; $col = '#2563EB' }
        elseif (-not $on -and $k -eq $cur) { $txt = '开启保护时使用'; $col = '#64748B' }
        foreach ($tb in @($pair[3], $pair[4])) { $tb.Text = $txt; $tb.Foreground = B $col }
        $en = (-not $script:busy) -and ($k -eq 'verge' -or $script:bcLoaded)
        $pair[1].IsEnabled = $en; $pair[2].IsEnabled = $en
    }
    $script:fillingMode = $false
    $modeHint.Text = $(if ($script:busy) { '正在执行其他操作…' } elseif ($on) { '点击即可热切换，不关闭保护' } else { '保护未开启：选好后在下次开启时生效' })
}

function Invoke-ModeClick([string]$k) {
    if ($script:fillingMode -or -not $script:snap) { return }
    $es = $script:snap.es
    $on = Test-On
    $cur = Get-ModeKey $es.engine $es.netMode
    $info = $ModeInfo[$k]
    if ($script:busy) { Update-Modes $script:snap; return }
    if (-not $on) {
        Save-Setting 'pendingEngine' $(if ($info.engine -ne $es.engine) { $info.engine } else { '' })
        Save-Setting 'pendingNetMode' $(if ($info.engine -eq 'builtin' -and $info.netMode -ne $es.netMode) { $info.netMode } else { '' })
        Show-Notice '已选择运行模式' ('{0}，下次开启保护时生效。' -f $info.label)
        return
    }
    if ($k -eq $cur) { Update-Modes $script:snap; return }
    $engineChange = ($info.engine -ne $es.engine)
    if ($engineChange) {
        $how = $(if ($info.engine -eq 'builtin') { "· 结束 Clash Verge，内置内核立即接管（新连接约等 2~4 秒）`n· Clash Verge 的配置还原成白羊原始配置" }
                 else { "· 浏览器先桥接到内置内核，启动 Clash Verge、确认严格配置生效后再停内置内核（约 10~30 秒）" })
        $r = [System.Windows.MessageBox]::Show(("切换到：{0}`n{1}`n· 正在进行的下载 / 流式回复会断开重连`n· 全程保持防火墙默认拒绝，不会回落直连`n`n继续吗？" -f $info.label, $how), 'Claude 保护 · 热切换', 'YesNo', 'Question')
        if ($r -ne 'Yes') { Update-Modes $script:snap; return }
    }
    $a = @{ Engine = $(if ($info.engine -eq 'builtin') { 'Builtin' } else { 'Verge' }) }
    if ($info.engine -eq 'builtin') { $a.NetMode = $(if ($info.netMode -eq 'sysproxy') { 'SysProxy' } else { 'Tun' }) }
    Start-Switch $a $info.label
}

# ================================================================= 引擎与节点页
function Update-EnginePanel($s) {
    $es = $s.es; $on = Test-On
    if (-not $script:bcLoaded) {
        $valEngine.Text = '缺少内置引擎模块，请在「维护」里更新到最新版'; $valEngine.Foreground = B '#B45309'
        $boxConflict.Visibility = 'Collapsed'; return
    }
    $txt = '当前：' + $ModeInfo[(Get-ModeKey $es.engine $es.netMode)].label; $color = '#0F172A'
    if (-not $es.builtin) {
        $txt += $(switch ([string]$s.vmode) { 'strict' { '（严格配置）' } 'original' { '（白羊原始配置）' } default { '' } })
        if ($on -and [string]$s.vmode -ne 'strict' -and (Get-ConfigMode) -eq 'Strict') { $txt += '。保护开启中但 Clash Verge 配置被改动了（可能打开过白羊官方 App），请关闭后重新开启保护'; $color = '#DC2626' }
    } else { $color = '#15803D' }
    if ($on) { $txt += '　·　保护开启中，点击下方卡片即可热切换' }
    $valEngine.Text = $txt; $valEngine.Foreground = B $color
    $wantVerge = ($(if ($on) { $es.engine } else { $es.wantEngine }) -eq 'verge')
    $panelVergeMode.Visibility = $(if ($wantVerge) { 'Visible' } else { 'Collapsed' })
    $engineHint.Text = $(if ($on) { '内置 TUN ⇄ 系统代理：同一个内核热重载，1~3 秒。内置 ⇄ Clash Verge：先准备好新内核再停旧的，浏览器全程不断；全程防火墙默认拒绝，不会直连。' }
                         else { '保护未开启：选好后在下次「开启保护」时生效。系统代理模式下，不认系统代理的程序会断网而不是直连。' })
    $conf = @($s.conf)
    if ($conf.Count -gt 0 -and ($es.builtin -or $es.wantEngine -eq 'builtin')) {
        $names = (@($conf | ForEach-Object { $_.name } | Select-Object -Unique)) -join '、'
        $txtConflict.Text = $(if ($on -and $es.builtin) { "检测到 $names 正在运行。它已被防火墙隔离（连不出去，不会泄露），但可能和内置引擎抢路由，建议结束。" } else { "检测到 $names 正在运行。开启保护时会自动结束它们（只结束进程，不改它们的配置）。" })
        $btnKillConflict.Visibility = $(if ($on -and $es.builtin) { 'Visible' } else { 'Collapsed' })
        $boxConflict.Visibility = 'Visible'
    } else { $boxConflict.Visibility = 'Collapsed' }
}

$script:fillingSrc = $false
function Update-CfgPanel($s) {
    if (-not $script:bpLoaded) { $valEngine.Text = '缺少配置模块，请在「维护」里点「完整修复」'; $valEngine.Foreground = B '#DC2626'; $btnSub.IsEnabled = $false; return }
    Update-EnginePanel $s
    $es = $s.es
    $builtinView = ($es.wantEngine -eq 'builtin' -and $script:bcLoaded)
    $panelSource.Visibility = $(if ($builtinView) { 'Visible' } else { 'Collapsed' })
    $btnImport.Visibility = $(if ($builtinView) { 'Visible' } else { 'Collapsed' })
    $sm = $s.sub
    if ($builtinView) {
        $script:fillingSrc = $true
        if ($es.wantSource -eq 'local') { $rbSrcLocal.IsChecked = $true } else { $rbSrcBaiyang.IsChecked = $true }
        $rbSrcLocal.Content = $(if ($sm -and $sm.localName) { '导入的本地配置（{0}）' -f $sm.localName } else { '导入的本地配置（未导入）' })
        $script:fillingSrc = $false
    }
    $kv = [ordered]@{}
    if ($builtinView -and $es.wantSource -ne $es.source) { $kv['待生效'] = ('节点来源改为「{0}」，锁定节点后生效' -f $(if ($es.wantSource -eq 'local') { '本地配置' } else { '白羊订阅' })) }
    if ($sm -and $sm.ok) {
        $kv['名称'] = $(if ($sm.name) { $sm.name } else { '白羊加速' })
        if ($sm.host) { $kv['订阅域名'] = $sm.host }
        $kv['节点数'] = ('{0} 个' -f $sm.nodeCount)
        if ($builtinView) { $kv['自动更新'] = $(if ($es.wantSource -eq 'local') { '本地配置不自动更新（重新导入即可）' } else { '保护开启时每 60 分钟检查一次；出口检测连续失败时立即检查' }) }
        else { $kv['自动更新'] = $(if ($sm.interval) { '每 {0} 分钟（Clash Verge）' -f $sm.interval } else { '-' }) }
        $kv['文件更新于'] = $(if ($sm.fileTime) { ([datetime]$sm.fileTime).ToString('yyyy-MM-dd HH:mm') } else { '-' })
        if ($sm.total) {
            $used = [double]$sm.upload + [double]$sm.download
            $kv['已用流量'] = ('{0} / {1}（{2:N1}%）' -f (Format-Bytes $used), (Format-Bytes $sm.total), (100.0 * $used / [Math]::Max([double]1, [double]$sm.total)))
        }
        $exp = From-Epoch $sm.expire
        if ($exp) { $kv['到期时间'] = ('{0}（剩 {1} 天）' -f $exp.ToString('yyyy-MM-dd'), [int][Math]::Floor(($exp - (Get-Date)).TotalDays)) }
        $kv['锁定节点入口'] = $(if ($sm.server) { '{0} : {1}' -f $sm.server, $sm.port } else { '!这里面没有锁定的节点，请在下方重新选择' })
    } else { $kv['订阅'] = $(if ($builtinView -and $es.wantSource -eq 'local') { '!还没有导入本地配置' } else { '!没有找到白羊订阅' }) }
    $subOnly = ($builtinView -and $es.wantSource -eq 'local')
    if ($script:subBusy) { $kv['最近一次检查'] = '正在更新订阅…'; $btnSub.IsEnabled = $false; $btnSub.Content = '更新中…' }
    else {
        $btnSub.IsEnabled = -not $subOnly; $btnSub.Content = '更新订阅'
        $r = $s.subRes
        if ($r -and -not $subOnly) { $kv['最近一次检查'] = ('{0}{1}　{2}' -f $(if ($r.ok) { '' } else { '!' }), (Format-Time ([string]$r.ts) 'MM-dd HH:mm'), $(if ($r.auto) { '[自动] ' + $r.message } else { $r.message })) }
    }
    Set-KV $kvSub $kv 120
    $subHint.Text = $(if ($builtinView) { '白羊订阅由本程序自己拉取（失败时自动换官方镜像地址）；锁定节点的端口变了会自动热重载内核，不断网。导入本地配置只使用其中的节点，规则一律用内置严格规则。' }
                     else { 'Clash Verge 每 30 分钟自动更新订阅；出口检测连续失败时本程序也会自动检查一次，锁定节点的端口变了会自动更新并重启 Clash。' })
}

function Update-PinPanel($s) {
    if (-not $script:bpLoaded) { $btnPin.IsEnabled = $false; return }
    $pin = $s.pin; $es = $s.es
    $pending = [string]$es.pinPending
    $kv = [ordered]@{}
    $kv['当前锁定'] = $pin.name
    $kv['期望出口'] = $(if ($pin.country) { '{0}（{1}）' -f $pin.cname, $pin.country } else { '!未知' })
    $kv['锁定于'] = $(if ($pin.since) { Format-Time $pin.since 'yyyy-MM-dd HH:mm' } else { '默认节点' })
    if ($pending -and $pending -ne $pin.name) { $kv['待生效'] = ('{0}（下次开启保护时生效）' -f $pending) }
    if ($es.wantEngine -ne 'builtin' -and (Get-ConfigMode) -ne 'Strict') { $kv['注意'] = '!当前是「保持当前配置」模式，开启保护不会改动 Clash 配置，锁定节点不生效' }
    Set-KV $kvPin $kv 90

    $nodes = @(); if ($s.sub) { $nodes = @($s.sub.nodes) }
    $sig = (@($nodes | ForEach-Object { $_.name }) -join '|') + '#' + $pin.name + '#' + $pending
    if ($cbNodes.Tag -ne $sig) {
        $prevSel = $(if ($cbNodes.SelectedItem) { [string]$cbNodes.SelectedItem.Tag } else { '' })
        $script:fillingNodes = $true
        $cbNodes.Items.Clear()
        $want = $(if ($prevSel) { $prevSel } elseif ($pending) { $pending } else { $pin.name })
        foreach ($n in $nodes) {
            $it = New-Object System.Windows.Controls.ComboBoxItem
            $cc = $(if ($n.country) { $n.country } else { '?' })
            $cname = $(if ($n.country) { Get-BPCountryName $n.country } else { '未知地区' })
            $mark = $(if ($n.name -eq $pin.name) { '　· 当前锁定' } elseif ($n.name -eq $pending) { '　· 待生效' } else { '' })
            $it.Content = ('{0}（{1}）　{2}　[{3}]{4}' -f $cname, $cc, $n.name, $n.type, $mark)
            $it.Tag = $n.name
            [void]$cbNodes.Items.Add($it)
            if ($n.name -eq $want) { $cbNodes.SelectedItem = $it }
        }
        if (-not $cbNodes.SelectedItem -and $cbNodes.Items.Count -gt 0) { $cbNodes.SelectedIndex = 0 }
        $script:fillingNodes = $false
        $cbNodes.Tag = $sig
        $script:nodeList = $nodes
    }
    Update-PinHint
}

function Get-SelectedNode {
    if (-not $cbNodes.SelectedItem) { return $null }
    $nm = [string]$cbNodes.SelectedItem.Tag
    foreach ($n in @($script:nodeList)) { if ($n.name -eq $nm) { return $n } }
    return $null
}

function Update-PinHint {
    if (-not $script:snap) { return }
    $n = Get-SelectedNode
    $pin = $script:snap.pin; $es = $script:snap.es
    $srcChange = ($es.wantEngine -eq 'builtin' -and $es.wantSource -ne $es.source)
    $base = '只会使用锁定的这一个节点；它不可用时直接断网，不会换到其他节点。守护会按该节点所在的国家/地区校验出口。'
    $pinHint.Foreground = B '#94A3B8'
    if (-not $n) { $btnPin.IsEnabled = $false; $pinHint.Text = '当前节点来源里没有可选的节点，请先更新订阅或导入配置。'; return }
    if ($script:busy) { $btnPin.IsEnabled = $false; $pinHint.Text = '正在执行其他操作，请稍候…'; return }
    if (-not $n.country) { $btnPin.IsEnabled = $false; $pinHint.Text = '无法从节点名称识别国家/地区，不能锁定（守护需要知道期望的出口国家）。'; $pinHint.Foreground = B '#DC2626'; return }
    $on = Test-On
    if ($n.name -eq $pin.name -and -not $srcChange) { $btnPin.IsEnabled = $false; $btnPin.Content = '已锁定'; $pinHint.Text = $base; return }
    $btnPin.IsEnabled = $true
    $btnPin.Content = $(if ($on) { '切换到此节点' } else { '锁定此节点' })
    if ($script:BP_ClaudeUnsupported -contains $n.country) {
        $pinHint.Text = ('注意：{0}（{1}）是 Claude 不提供服务的地区，锁定后 Claude 很可能无法使用。' -f (Get-BPCountryName $n.country), $n.country)
        $pinHint.Foreground = B '#B45309'
    } else {
        $pinHint.Text = $(if ($on) { $(if ($es.builtin) { '保护开启中：内置引擎换节点是热重载，约 1~3 秒，不断开保护。' } else { '保护开启中：Clash Verge 换节点需要重启它，约半分钟 Claude 无法联网。' }) } else { '保护未开启：选好后会在下次「开启保护」时生效。' }) + $base
    }
}

function Invoke-PinNode {
    $n = Get-SelectedNode
    if (-not $n -or -not $n.country) { return }
    $es = $script:snap.es
    if ($es.wantEngine -ne 'builtin' -and (Get-ConfigMode) -ne 'Strict') {
        [System.Windows.MessageBox]::Show('当前是「保持当前配置」模式，不会改动 Clash 配置。请先把 Clash Verge 配置改成「切换配置」。', 'Claude 保护') | Out-Null; return
    }
    $cn = Get-BPCountryName $n.country
    $warn = $(if ($script:BP_ClaudeUnsupported -contains $n.country) { "`n`n注意：$cn 是 Claude 不提供服务的地区，锁定后 Claude 很可能无法使用。" } else { '' })
    if (Test-On) {
        $r = [System.Windows.MessageBox]::Show(("切换锁定节点到：`n{0}`n期望出口：{1}（{2}）`n`n{3}继续吗？{4}" -f $n.name, $cn, $n.country, $(if ($es.builtin) { "内置引擎热重载，约 1~3 秒，不关闭保护。`n" } else { "需要重启 Clash Verge，约半分钟 Claude 无法联网。`n" }), $warn), 'Claude 保护 · 切换节点', 'YesNo', 'Question')
        if ($r -ne 'Yes') { return }
        $a = @{ NodeB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($n.name)) }
        if ($es.wantSource -ne $es.source -and $es.builtin) { $a.Source = $(if ($es.wantSource -eq 'local') { 'Local' } else { 'Baiyang' }) }
        Save-Setting 'pinNode' $n.name
        Start-Switch $a ('节点 ' + $n.name)
    } else {
        if ($warn) { $r = [System.Windows.MessageBox]::Show(("锁定节点：{0}{1}`n`n仍然选择它吗？" -f $n.name, $warn), 'Claude 保护', 'YesNo', 'Warning'); if ($r -ne 'Yes') { return } }
        Save-Setting 'pinNode' $n.name
        Show-Notice '已选择锁定节点' ('{0}，下次开启保护时生效。' -f $n.name)
    }
    $cbNodes.Tag = $null
}

function Set-SourceChoice([string]$src) {
    if ($script:fillingSrc -or -not $script:snap) { return }
    $es = $script:snap.es
    if ($src -eq 'local' -and -not (Test-Path -LiteralPath (Get-BCSubFile 'local'))) {
        [System.Windows.MessageBox]::Show('还没有导入过本地配置，请先点「导入本地配置…」。', 'Claude 保护') | Out-Null
        $script:fillingSrc = $true; $rbSrcBaiyang.IsChecked = $true; $script:fillingSrc = $false
        return
    }
    Save-Setting 'pendingSource' $(if ($src -ne $es.source) { $src } else { '' })
    $cbNodes.Tag = $null
}

# ================================================================= 后台任务（导入配置 / 结束 Claude 进程）
function Start-BgJob([string]$name, [string]$code, $arg = $null) {
    $rs = [runspacefactory]::CreateRunspace(); $rs.Open()
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    $pre = '$ErrorActionPreference = ''Stop''; . (Join-Path $args[0] ''BaiyangProfile.ps1''); . (Join-Path $args[0] ''BuiltinCore.ps1''); $a = $args[1]' + "`n"
    [void]$ps.AddScript($pre + $code).AddArgument($script:ModDir).AddArgument($arg)
    $script:bgJobs += @{ name = $name; ps = $ps; rs = $rs; h = $ps.BeginInvoke(); arg = $arg }
}
function Test-BgJobs {
    if ($script:bgJobs.Count -eq 0) { return }
    $keep = @()
    foreach ($j in $script:bgJobs) {
        if (-not $j.h.IsCompleted) { $keep += $j; continue }
        $res = $null; $err = ''
        try { $res = @($j.ps.EndInvoke($j.h)) | Select-Object -Last 1 } catch { $err = $_.Exception.InnerException.Message; if (-not $err) { $err = $_.Exception.Message } }
        try { $j.ps.Dispose(); $j.rs.Dispose() } catch {}
        switch ($j.name) {
            'import' {
                $win.Cursor = $null
                if ($err) { [System.Windows.MessageBox]::Show(('导入失败：' + $err), 'Claude 保护', 'OK', 'Warning') | Out-Null; break }
                $es = $script:snap.es
                Save-Setting 'pendingSource' $(if ($es.source -ne 'local') { 'local' } else { '' })
                $cbNodes.Tag = $null
                Show-Notice '已导入本地配置' ('{0}：{1} 个节点。请在下方选择要锁定的节点。' -f (Split-Path $j.arg -Leaf), $res)
            }
            'kill' {
                $win.Cursor = $null
                if ($err) { Show-Notice '结束 Claude 程序失败' $err 'Warning'; break }
                if ($res.Left -eq 0) { Show-Notice '已结束所有 Claude 程序' ('共结束 {0} 个进程，没有残留。' -f $res.Found); $btnKill.Content = '已全部结束'; $script:killBtnReset = (Get-Date).AddSeconds(4) }
                else { [System.Windows.MessageBox]::Show(('已结束 {0} 个，仍有 {1} 个无法结束（可能以管理员身份运行），请在任务管理器中手动结束。' -f ($res.Found - $res.Left), $res.Left), 'Claude 保护', 'OK', 'Warning') | Out-Null }
                $btnKill.IsEnabled = $true; $sync.forceProcs = $true; $sync.wake = $true
            }
        }
    }
    $script:bgJobs = $keep
}

function Invoke-ImportLocal {
    if (-not $script:bcLoaded) { return }
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Title = '选择 Clash / mihomo 配置文件（只会使用其中的节点，规则一律用内置严格规则）'
    $dlg.Filter = 'Clash 配置 (*.yaml;*.yml)|*.yaml;*.yml|所有文件 (*.*)|*.*'
    if (-not $dlg.ShowDialog($win)) { return }
    $win.Cursor = [System.Windows.Input.Cursors]::AppStarting
    Start-BgJob 'import' 'Import-BCLocal $a' $dlg.FileName
}

function Invoke-KillClaude {
    if (-not $script:bpLoaded) { return }
    $n = @($script:snap.procs).Count
    $r = [System.Windows.MessageBox]::Show(("将强制结束所有 Claude 相关进程（Claude 桌面版、Claude Code 等{0}），未保存的内容会丢失。`n`n确定吗？" -f $(if ($n -gt 0) { "，共 $n 个" } else { '' })), 'Claude 保护 · 结束所有 Claude 程序', 'YesNo', 'Warning')
    if ($r -ne 'Yes') { return }
    $btnKill.IsEnabled = $false; $win.Cursor = [System.Windows.Input.Cursors]::AppStarting
    Start-BgJob 'kill' 'Stop-BPClaudeProcesses'
}

function Invoke-KillConflicts {
    $r = [System.Windows.MessageBox]::Show("将结束 Clash Verge / 白羊 App 的界面和内核进程（需要管理员授权；只结束进程，不改它们的配置）。`n`n继续吗？", 'Claude 保护', 'YesNo', 'Question')
    if ($r -ne 'Yes') { return }
    $cmd = "Get-Process -Name baiyang,clash-verge,verge-mihomo,verge-mihomo-alpha,clash-meta,mihomo,clash -ErrorAction SilentlyContinue | Stop-Process -Force"
    try { Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList ('-NoProfile -WindowStyle Hidden -Command "{0}"' -f $cmd) } catch {}
}

# ================================================================= 网络页 / 进程页 / 维护页
function Update-NetworkPage($s) {
    # 只展示属于当前引擎、且是近几秒采集的数据；否则清空并提示“正在读取”，不让旧内容冒充实时状态
    $d = $s.net
    $age = 999.0
    if ($d -and $d.t) { try { $age = ((Get-Date) - [DateTime]$d.t).TotalSeconds } catch {} }
    $fresh = ($d -and [string]$d.engine -eq [string]$s.es.engine -and [string]$d.netMode -eq [string]$s.es.netMode -and $age -le 20)
    if (-not $fresh) {
        $netStamp.Text = $(if ($script:busy -or ($s.progress -and $s.progress.live)) { '正在切换，切换完成后显示新内核的状态…' } else { '正在读取实时状态…' })
        $netStamp.Foreground = B '#B45309'
        if ($kvCore.Tag -ne 'pending') {
            foreach ($p in @($kvCore, $kvTun, $kvPhys)) { $p.Children.Clear(); $p.Tag = 'pending' }
            [void]$kvCore.Children.Add((New-Tb '读取中…' '#94A3B8' 13))
        }
        return
    }
    $netStamp.Text = ('实时数据 · 更新于 {0:HH:mm:ss}（每 2 秒刷新，采集用时 {1} ms）' -f [DateTime]$d.t, [int]$d.ms)
    $netStamp.Foreground = B '#64748B'
    $titCore.Text = [string]$d.titCore; $titTun.Text = [string]$d.titTun
    Set-KV $kvCore $d.kvCore; Set-KV $kvTun $d.kvTun; Set-KV $kvPhys $d.kvPhys
}

$TestScript = {
    param([bool]$includeClaude)
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
    $targets = @()
    if ($includeClaude) {
        $targets += @{ n = 'Claude API';   u = 'https://api.anthropic.com/cdn-cgi/trace' }
        $targets += @{ n = 'Claude 网页';  u = 'https://claude.ai/cdn-cgi/trace' }
    }
    $targets += @{ n = 'Cloudflare';   u = 'https://www.cloudflare.com/cdn-cgi/trace' }
    foreach ($t in $targets) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try {
            $r = Invoke-WebRequest -Uri $t.u -UseBasicParsing -TimeoutSec 15
            $ms = $sw.Elapsed.TotalMilliseconds
            $c = [string]$r.Content; $loc = ''; $ip = ''
            if ($c -match '(?m)^loc=(\S+)') { $loc = $Matches[1] }
            if ($c -match '(?m)^ip=(\S+)') { $ip = $Matches[1] }
            [pscustomobject]@{ name = $t.n; ok = $true; ms = $ms; loc = $loc; ip = $ip; err = '' }
        } catch {
            [pscustomobject]@{ name = $t.n; ok = $false; ms = $sw.Elapsed.TotalMilliseconds; loc = ''; ip = ''; err = $_.Exception.Message }
        }
    }
}
function Start-ConnTest {
    if ($script:testJob) { return }
    # 保护没开（或没在正常放行）时不访问 Claude 的站点：否则是用真实 IP 直连 Claude
    $safe = ($script:status -and $script:status.key -eq 'ok')
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript($TestScript).AddArgument($safe)
    $script:testJob = @{ ps = $ps; handle = $ps.BeginInvoke(); started = Get-Date; safe = $safe }
    $btnTest.IsEnabled = $false; $btnTest.Content = '测试中…'
    $panelTest.Children.Clear()
    [void]$panelTest.Children.Add((New-Tb '正在测试，最长约 45 秒…' '#64748B' 13))
}
function Test-ConnTestDone {
    if (-not $script:testJob -or -not $script:testJob.handle.IsCompleted) { return }
    $res = @()
    try { $res = @($script:testJob.ps.EndInvoke($script:testJob.handle)) } catch {}
    try { $script:testJob.ps.Dispose() } catch {}
    $wasSafe = [bool]$script:testJob.safe
    $script:testJob = $null
    $btnTest.IsEnabled = $true; $btnTest.Content = '重新测试'
    $panelTest.Children.Clear()
    $w = [double[]]@(130, 90, 110, 0)
    Add-TableRow $panelTest @('目标', '结果', '用时', '出口') $w $true
    foreach ($r in $res) {
        if ($r.ok) {
            $exp = $(if ($script:snap) { $script:snap.pin.country } else { 'KR' })
            $locTxt = $r.loc; if ($script:bpLoaded) { $cn = Get-BPCountryName $r.loc; if ($cn -and $cn -ne $r.loc) { $locTxt = '{0} {1}' -f $cn, $r.loc } }
            $locCol = $(if ($r.loc -eq $exp) { '#15803D' } else { '#DC2626' })
            $msCol = $(if ($r.ms -lt 1500) { '#15803D' } elseif ($r.ms -lt 4000) { '#B45309' } else { '#DC2626' })
            Add-TableRow $panelTest @($r.name, '成功', ('{0:N0} ms' -f $r.ms), ('{0}　{1}' -f $locTxt, $r.ip)) $w $false @('#0F172A', '#15803D', $msCol, $locCol)
        } else {
            $e = [string]$r.err; if ($e.Length -gt 60) { $e = $e.Substring(0, 60) + '…' }
            Add-TableRow $panelTest @($r.name, '失败', ('{0:N0} ms' -f $r.ms), $e) $w $false @('#0F172A', '#DC2626', '#64748B', '#64748B')
        }
    }
    if (-not $wasSafe) {
        $t = New-Tb '保护未开启（或 Claude 正被拦截），这次没有访问 Claude 的站点，避免用真实 IP 直连 Claude。开启保护后再测即可看到 Claude 的结果。' '#B45309' 12
        $t.Margin = New-Object System.Windows.Thickness(0, 6, 0, 0); [void]$panelTest.Children.Add($t)
    }
}

function Update-ProcsPage($s) {
    $list = @($s.procs)
    $sig = ($list | ForEach-Object { '{0}:{1}' -f $_.pid, [int]($_.mem / 4MB) }) -join ','
    if ($panelProcs.Tag -eq $sig -and $panelProcs.Children.Count -gt 0) { return }
    $panelProcs.Tag = $sig
    $panelProcs.Children.Clear()
    if ($null -eq $s.procs) { $procSummary.Text = '正在读取…'; return }
    if ($list.Count -eq 0) {
        $procSummary.Text = '没有正在运行的 Claude 程序'
        [void]$panelProcs.Children.Add((New-Tb '已全部退出，没有残留进程。' '#64748B' 13))
        return
    }
    $mem = ($list | Measure-Object -Property mem -Sum).Sum
    $procSummary.Text = ('{0} 个进程 · 内存 {1}' -f $list.Count, (Format-Bytes $mem))
    $w = [double[]]@(180, 80, 100, 130, 0)
    Add-TableRow $panelProcs @('类型', 'PID', '内存', '启动时间', '程序位置') $w $true
    foreach ($p in $list) { Add-TableRow $panelProcs @($p.kind, [string]$p.pid, (Format-Bytes $p.mem), $p.start, $p.path) $w }
}

function Update-VerPanel($s) {
    $u = $s.update
    $kv = [ordered]@{}
    $kv['控制台'] = "v$HubVersion"
    $kv['守护服务'] = $(if ($s.st -and $s.st.version) { 'v' + $s.st.version } else { '-' })
    $kv['运行模式'] = $ModeInfo[(Get-ModeKey $s.es.engine $s.es.netMode)].label
    if ($s.es.builtin) { $kv['内置内核'] = $(if ($s.coreVer) { $s.coreVer } else { '读取中…' }) } else { $kv['严格规则'] = $(if ($s.ruleVer) { $s.ruleVer } else { '-' }); $kv['Clash 内核'] = $(if ($s.coreVer) { $s.coreVer } else { '读取中…' }) }
    $kv['安装位置'] = $Root
    $kv['套件文件夹'] = $(if ($u -and $u.suite) { $u.suite } elseif ($u) { '!未记录' } else { '读取中…' })
    Set-KV $kvVer $kv 110
    Update-VersionList $s
    if (-not $u) { return }
    if (-not $u.suite) {
        $valVer.Text = '未记录套件文件夹位置。请先运行一次套件文件夹里的「更新控制台.bat」，之后就能在这里更新。'; $valVer.Foreground = B '#B45309'
        $btnUpdate.IsEnabled = $false; $btnRepair.IsEnabled = $false; return
    }
    $btnRepair.IsEnabled = $true
    if (@($u.changed).Count -gt 0) {
        $valVer.Text = ('发现新版本：套件文件夹里有 {0} 个文件已更新（{1}）。' -f @($u.changed).Count, (@($u.changed) -join '、'))
        $valVer.Foreground = B '#1D4ED8'
        if (-not $script:updating) { $btnUpdate.IsEnabled = $true; $btnUpdate.Content = '更新到最新版' }
    } else {
        $valVer.Text = '已是最新版本。'; $valVer.Foreground = B '#15803D'
        $btnUpdate.IsEnabled = $false; $btnUpdate.Content = '已是最新版'
    }
}
function Update-UpdateBadge($s) {
    $u = $s.update
    $n = (C 'navMaint')
    if ($u -and $u.suite -and @($u.changed).Count -gt 0) {
        if ([string]$n.Content -ne '维护　●') { $n.Content = '维护　●' }
        $sig = @($u.changed) -join '|'
        if ($sig -ne $script:notifiedUpdateSig) { $script:notifiedUpdateSig = $sig; Show-Notice 'Claude 保护有新版本' '打开控制台，在「维护」里点「更新到最新版」（不断网、不中断 Claude）。' }
    } elseif ([string]$n.Content -ne '维护') { $n.Content = '维护' }
}

function Update-VersionList($s) {
    $list = @($s.versions)
    $sig = ($list | ForEach-Object { $_.id }) -join '|'
    if ($cbVersions.Tag -ne $sig) {
        $cbVersions.Items.Clear()
        foreach ($v in $list) {
            $it = New-Object System.Windows.Controls.ComboBoxItem
            $it.Content = ('v{0}　保存于 {1}　{2}' -f $v.version, (Format-Time $v.ts 'yyyy-MM-dd HH:mm'), $v.note)
            $it.Tag = $v.id
            [void]$cbVersions.Items.Add($it)
        }
        if ($cbVersions.Items.Count -gt 0) { $cbVersions.SelectedIndex = 0 }
        $cbVersions.Tag = $sig
    }
    $ok = ($list.Count -gt 0 -and (Test-Path -LiteralPath $RollbackScript) -and -not $script:busy)
    $btnRollback.IsEnabled = $ok
    if ($list.Count -eq 0) { $cbVersions.IsEnabled = $false; $btnRollback.Content = '暂无可回退的版本' } else { $cbVersions.IsEnabled = $true; if (-not $script:rollingBack) { $btnRollback.Content = '回退到此版本' } }
}

function Invoke-Rollback {
    if (-not $cbVersions.SelectedItem) { return }
    $id = [string]$cbVersions.SelectedItem.Tag
    $r = [System.Windows.MessageBox]::Show(("回退到：{0}`n`n· 会先关闭保护（恢复普通网络）`n· 当前版本 v{1} 也会保存，之后可以再回来`n· 回退完成后控制台自动重启，需要时重新「开启保护」`n`n继续吗？" -f $cbVersions.SelectedItem.Content, $HubVersion), 'Claude 保护 · 版本回退', 'YesNo', 'Warning')
    if ($r -ne 'Yes') { return }
    try { Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Id {1} -NoPause' -f $RollbackScript, $id) } catch { return }
    $script:rollingBack = $true; $btnRollback.IsEnabled = $false; $btnRollback.Content = '正在回退…'
    Show-Notice '正在回退版本' '完成后控制台会自动重启。'
}

function Get-SuiteDir { if ($script:snap -and $script:snap.update -and $script:snap.update.suite) { return [string]$script:snap.update.suite }; try { $s = (Get-Content -LiteralPath $SuiteFile -Raw -Encoding UTF8 | ConvertFrom-Json).path; if ($s -and (Test-Path -LiteralPath $s)) { return [string]$s } } catch {}; return $null }
function Invoke-SelfUpdate {
    $suite = Get-SuiteDir
    $scr = $(if ($suite) { Join-Path $suite '更新控制台.ps1' } else { $null })
    if (-not $scr -or -not (Test-Path -LiteralPath $scr)) { [System.Windows.MessageBox]::Show('找不到套件文件夹里的「更新控制台.ps1」。', 'Claude 保护') | Out-Null; return }
    try { Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -NoPause' -f $scr) } catch { return }
    $script:updating = $true; $btnUpdate.IsEnabled = $false; $btnUpdate.Content = '正在更新…'
    Show-Notice '正在更新 Claude 保护' '控制台会自动重启，网络和 Claude 不受影响。'
}
function Invoke-Repair {
    $suite = Get-SuiteDir
    $bat = $(if ($suite) { Join-Path $suite '修复-Claude安全网络.bat' } else { $null })
    if (-not $bat -or -not (Test-Path -LiteralPath $bat)) { [System.Windows.MessageBox]::Show('找不到套件文件夹里的「修复-Claude安全网络.bat」。', 'Claude 保护') | Out-Null; return }
    $r = [System.Windows.MessageBox]::Show("完整修复会：`n· 退出 Clash / 白羊 App / UU，清理残留隧道和 DNS`n· 重写严格配置、重装守护，然后验证出口国家`n`n期间会短暂断网，并弹出一个窗口要求输入 YES 确认。`n一般只在「开启保护」一直失败时使用。继续吗？", 'Claude 保护 · 完整修复', 'YesNo', 'Warning')
    if ($r -ne 'Yes') { return }
    try { Start-Process -FilePath $bat -WorkingDirectory $suite } catch {}
}
function Start-RescueFromUi {
    $r = [System.Windows.MessageBox]::Show("仅在「关闭保护」无效时使用。`n应急恢复会撤销全部防火墙限制并停用守护服务，网络回到普通直连。`n`n确定执行吗？", 'Claude 保护 · 应急恢复', 'YesNo', 'Warning')
    if ($r -ne 'Yes') { return }
    if (-not (Test-Path -LiteralPath $GuardScript)) { [System.Windows.MessageBox]::Show("未找到 $GuardScript", 'Claude 保护') | Out-Null; return }
    try { Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$GuardScript`" -Mode Rescue" } catch {}
}

# ================================================================= 订阅
function Start-SubRefresh([bool]$Auto) {
    if ($script:subBusy -or -not $script:bpLoaded) { return }
    $scr = Join-Path $PSScriptRoot 'Refresh-Subscription.ps1'
    if (-not (Test-Path -LiteralPath $scr)) { $scr = Join-Path $Root 'bin\Refresh-Subscription.ps1' }
    if (-not (Test-Path -LiteralPath $scr)) { if (-not $Auto) { [System.Windows.MessageBox]::Show('未找到 Refresh-Subscription.ps1，请在「维护」里更新。', 'Claude 保护') | Out-Null }; return }
    $a = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $scr
    if ($Auto) { $a += ' -Auto' }
    try { Start-Process powershell.exe -WindowStyle Hidden -ArgumentList $a } catch { return }
    $script:subBusy = @{ started = Get-Date; auto = $Auto }
    if ($Auto) { $script:lastAutoSub = Get-Date }
    if ($script:snap) { Update-CfgPanel $script:snap }
}
function Test-SubDone($s) {
    if (-not $script:subBusy) { return }
    $r = $s.subRes; $done = $false
    if ($r) {
        $ts = [DateTime]::MinValue
        try { $ts = [DateTime]::Parse([string]$r.ts, $null, [System.Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime() } catch {}
        if ($ts -ge $script:subBusy.started.AddSeconds(-2)) {
            $done = $true
            if (-not $r.ok) { if (-not $script:subBusy.auto) { Show-Notice '更新订阅失败' ([string]$r.message) 'Warning' } }
            elseif ($r.nodeChanged) { Show-Notice '锁定节点端口已更新' ([string]$r.message) }
            elseif (-not $script:subBusy.auto) { Show-Notice '订阅已检查' ([string]$r.message) }
        }
    }
    if (((Get-Date) - $script:subBusy.started).TotalSeconds -gt 150) { $done = $true }
    if ($done) { $script:subBusy = $null; $sync.wake = $true }
}
function Test-AutoSub($s) {
    # 出口检测连续失败 ≥2 次：可能是入口端口变了，自动检查一次订阅（每 10 分钟最多一次）
    if (-not $script:bpLoaded -or $script:subBusy -or $script:busy) { return }
    $st = $s.st
    if (-not $st -or [string]$st.mode -eq 'OFF' -or $st.switching) { return }
    $fs = 0; try { $fs = [int]$st.probe.failStreak } catch {}
    $since = ((Get-Date) - $script:lastAutoSub).TotalMinutes
    if ($fs -ge 2 -and $since -ge 10) { Start-SubRefresh $true; return }
    # 内置引擎没有 Clash Verge 的定时更新：保护开启时每 60 分钟自己检查一次白羊订阅
    if ($s.es.builtin -and $s.es.source -eq 'baiyang' -and $since -ge 60) {
        if ($script:lastAutoSub -eq [DateTime]::MinValue) { $script:lastAutoSub = Get-Date; return }
        Start-SubRefresh $true
    }
}

# ================================================================= 托盘
function New-StatusIcon([string]$hex, [string]$glyph) {
    $bmp = New-Object System.Drawing.Bitmap(32, 32)
    $gr = [System.Drawing.Graphics]::FromImage($bmp)
    $gr.SmoothingMode = 'AntiAlias'; $gr.TextRenderingHint = 'AntiAliasGridFit'
    $br = New-Object System.Drawing.SolidBrush([System.Drawing.ColorTranslator]::FromHtml($hex))
    $gr.FillEllipse($br, 1, 1, 30, 30)
    $font = New-Object System.Drawing.Font('Segoe MDL2 Assets', 15, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
    $sf = New-Object System.Drawing.StringFormat; $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
    $gr.DrawString($glyph, $font, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF(0, 1, 32, 32)), $sf)
    $gr.Dispose(); $br.Dispose(); $font.Dispose()
    return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}
$script:icons = @{}
function Get-Icon([string]$key) {
    if (-not $script:icons.ContainsKey($key)) { $p = $Palette[$key]; $script:icons[$key] = New-StatusIcon $p.color $p.glyph }
    return $script:icons[$key]
}
$script:trayIcon = $null
function Show-Notice([string]$title, [string]$text, [string]$kind = 'Info') {
    if (-not $script:trayIcon) { return }
    try { $script:trayIcon.ShowBalloonTip(5000, $title, $text, [System.Windows.Forms.ToolTipIcon]::$kind) } catch {}
}
function Update-Tray {
    if (-not $script:trayIcon -or -not $script:status) { return }
    $k = $script:status.key
    if ($script:trayKey -ne $k) {
        $script:trayKey = $k
        $script:trayIcon.Icon = Get-Icon $k
        try { $win.Icon = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon((Get-Icon $k).Handle, [System.Windows.Int32Rect]::Empty, [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions()) } catch {}
    }
    $tip = 'Claude 保护：' + $script:status.title
    if ($script:snap) { $tip += ' · ' + $ModeInfo[(Get-ModeKey $script:snap.es.engine $script:snap.es.netMode)].label }
    if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 63) }
    if ($script:trayIcon.Text -ne $tip) { $script:trayIcon.Text = $tip }
    $script:miToggle.Text = $(if ($k -eq 'off') { '开启保护' } else { '关闭保护' })
    $script:miToggle.Enabled = -not $script:busy
    $script:miProbe.Enabled = ($k -ne 'off')
    if ($script:snap) {
        $cur = Get-ModeKey $script:snap.es.engine $script:snap.es.netMode
        $want = Get-ModeKey $script:snap.es.wantEngine $script:snap.es.wantNetMode
        $sel = $(if ($k -ne 'off') { $cur } else { $want })
        foreach ($mk in $script:miModes.Keys) { $script:miModes[$mk].Checked = ($mk -eq $sel); $script:miModes[$mk].Enabled = (-not $script:busy) -and ($mk -eq 'verge' -or $script:bcLoaded) }
    }
}
function Invoke-Notify($s) {
    $k = $script:status.key
    $prev = $script:prevKey
    $st = $s.st
    if ($prev -and $k -ne $prev) {
        switch ($k) {
            'ok' {
                if ($prev -eq 'off' -or $prev -eq 'init') { Show-Notice '保护已开启' ('Claude 正在通过锁定的{0}节点安全连接。' -f $s.pin.cname) }
                else { Show-Notice '已恢复正常' '网络恢复，Claude 已重新放行。' }
            }
            'off'    { Show-Notice '保护已关闭' '现在是普通网络，Claude 未受保护。' 'Warning' }
            'locked' { Show-Notice '已拦截 Claude 连接' ([string]$st.reason) 'Warning' }
            'cut'    { Show-Notice '已断网保护' ([string]$st.reason) 'Error' }
            'lost'   { Show-Notice '守护服务未响应' '系统会自动重启守护服务，若持续出现请重新开启保护。' 'Warning' }
        }
    }
    $script:prevKey = $k
    if ($k -eq 'ok' -and $st.identity -and $st.identity.ok) {
        $ip = [string]$st.identity.ip
        if ($script:prevIp -and $ip -and $ip -ne $script:prevIp) { Show-Notice '出口 IP 已变化' ('新的出口：{0}（{1}）' -f $ip, $st.identity.country) }
        if ($ip) { $script:prevIp = $ip }
    }
}

# ================================================================= 开启 / 关闭 / 热切换（后台以管理员身份执行，无黑框）
function Find-Script([string]$name) {
    $p = Join-Path $Root ("bin\{0}" -f $name)
    if (Test-Path -LiteralPath $p) { return $p }
    $alt = switch ($name) { 'Resume.ps1' { 'Resume-恢复保护.ps1' } 'Pause.ps1' { 'Pause-关闭保护.ps1' } 'Switch.ps1' { 'Switch-热切换.ps1' } }
    foreach ($c in @((Join-Path $PSScriptRoot "..\..\$alt"), (Join-Path $PSScriptRoot "..\$alt"))) { if (Test-Path -LiteralPath $c) { return (Resolve-Path $c).Path } }
    return $null
}
function Set-Busy($b) { $script:busy = $b; $sync.busy = [bool]$b; $script:lastViewSig = ''; $sync.wake = $true; if ($script:snap) { Render $script:snap } }

function Invoke-Toggle([bool]$TurnOn) {
    if ($script:busy) { return }
    $name = $(if ($TurnOn) { 'Resume.ps1' } else { 'Pause.ps1' })
    $path = Find-Script $name
    if (-not $path) { [System.Windows.MessageBox]::Show("未找到 $name，请在「维护」里点「完整修复」。", 'Claude 保护') | Out-Null; return }
    try {
        $a = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -NoPause -ConfigMode {1}' -f $path, (Get-ConfigMode)
        if ($TurnOn) {
            # 控制台里选好、保护关闭时记下的：锁定节点 / 运行模式 / 节点来源
            $st = Get-Settings
            if ((Get-ConfigMode) -eq 'Strict' -and [string]$st.pinNode) { $a += ' -NodeB64 ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$st.pinNode)) }
            if ([string]$st.pendingEngine) { $a += ' -Engine ' + $(if ($st.pendingEngine -eq 'builtin') { 'Builtin' } else { 'Verge' }) }
            if ([string]$st.pendingNetMode) { $a += ' -NetMode ' + $(if ($st.pendingNetMode -eq 'sysproxy') { 'SysProxy' } else { 'Tun' }) }
            if ([string]$st.pendingSource) { $a += ' -Source ' + $(if ($st.pendingSource -eq 'local') { 'Local' } else { 'Baiyang' }) }
        }
        Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList $a
    } catch { return }   # 用户取消了管理员授权
    Set-Busy @{ target = $(if ($TurnOn) { 'on' } else { 'off' }); action = $(if ($TurnOn) { 'on' } else { 'off' }); started = Get-Date; label = '' }
}

function Start-Switch([hashtable]$Params, [string]$Label) {
    if ($script:busy) { return }
    $path = Find-Script 'Switch.ps1'
    if (-not $path) { [System.Windows.MessageBox]::Show('未找到热切换程序（Switch.ps1），请在「维护」里更新到最新版。', 'Claude 保护') | Out-Null; if ($script:snap) { Update-Modes $script:snap }; return }
    $a = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -NoPause -ConfigMode {1}' -f $path, (Get-ConfigMode)
    foreach ($k in $Params.Keys) { $a += (' -{0} {1}' -f $k, $Params[$k]) }
    try { Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList $a } catch { if ($script:snap) { Update-Modes $script:snap }; return }
    Set-Busy @{ target = 'switch'; action = 'switch'; started = Get-Date; label = $Label }
}

function Test-BusyDone($s) {
    if (-not $script:busy) { return }
    $r = $s.toggle
    $done = $false
    if ($r) {
        $ts = [DateTime]::MinValue
        try { $ts = [DateTime]::Parse([string]$r.ts, $null, [System.Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime() } catch {}
        $act = [string]$r.action
        if ($ts -ge $script:busy.started.AddSeconds(-2) -and (-not $act -or $act -eq $script:busy.action)) {
            $done = $true
            if ($r.ok -and $script:busy.target -ne 'off') { foreach ($k in @('pinNode', 'pendingEngine', 'pendingNetMode', 'pendingSource')) { Save-Setting $k '' } }
            $what = switch ($script:busy.target) { 'on' { '开启保护' } 'switch' { '热切换' } default { '关闭保护' } }
            if (-not $r.ok) {
                Show-Notice ($what + '失败') ([string]$r.message) 'Error'
                if ($win.IsVisible) { [System.Windows.MessageBox]::Show(([string]$r.message), ('Claude 保护 · ' + $what + '失败'), 'OK', 'Warning') | Out-Null }
            } elseif ($r.message -and $r.message -ne '保护已开启' -and $r.message -ne '保护已关闭') {
                Show-Notice $(switch ($script:busy.target) { 'on' { '保护已开启' } 'switch' { '切换完成' } default { '保护已关闭' } }) ([string]$r.message)
            }
        }
    }
    $limit = $(if ($script:busy.target -eq 'switch') { 300 } else { 240 })
    if (((Get-Date) - $script:busy.started).TotalSeconds -gt $limit) { $done = $true }
    if ($done) { $script:busy = $null; $sync.busy = $false; $script:lastViewSig = ''; $cbNodes.Tag = $null; $sync.wake = $true }
}

# ---------------------------------------------------------------- 立即检查出口：发指令 → 等守护回执 → 显示真实结果
$script:probeAsk = $null
function Set-ProbeMsg([string]$text, [string]$color) {
    if (-not $text) { $probeMsg.Visibility = 'Collapsed'; return }
    $probeMsg.Text = $text; $probeMsg.Foreground = B $color; $probeMsg.Visibility = 'Visible'
}
function Start-ProbeCheck([switch]$Tray) {
    if ($script:probeAsk) { return }
    $s = $script:snap
    $st = $(if ($s) { $s.st } else { $null })
    $why = ''
    if (-not $s -or -not $s.alive) { $why = '守护服务没有在运行，无法检查' }
    elseif ([string]$st.mode -eq 'OFF') { $why = '保护未开启' }
    elseif ($st.forced) { $why = '正在强制断网，不检查出口' }
    if ($why) { Set-ProbeMsg $why '#B45309'; if ($Tray) { Show-Notice '无法检查出口' $why 'Warning' }; return }
    if (-not (Send-GuardCommand 'probe-now')) { return }
    $script:probeAsk = @{ at = Get-Date; tray = [bool]$Tray }
    $btnProbe.IsEnabled = $false; $btnProbe.Content = '正在检查…'
    Set-ProbeMsg '已发给守护，等待结果…' '#64748B'
    $sync.wake = $true
}
function Test-ProbeDone($s) {
    $a = $script:probeAsk
    if (-not $a) { return }
    $st = $s.st; $pr = $(if ($st) { $st.probe } else { $null })
    $t = $null; try { if ($pr -and $pr.done) { $t = [DateTime]::Parse([string]$pr.done) } } catch {}
    $wait = ((Get-Date) - $a.at).TotalSeconds
    $title = ''; $text = ''; $color = '#64748B'; $kind = 'Info'
    if ($t -and $t -gt $a.at -and $pr.doneManual) {
        $id = $st.identity
        if ($pr.doneOk -and $id -and $id.ok) {
            $cn = [string]$id.country; if ($script:bpLoaded) { $x = Get-BPCountryName $cn; if ($x) { $cn = $x } }
            $good = ([string]$id.country -eq [string]$st.expected.country)
            $title = $(if ($good) { '出口正常' } else { '出口地区不符' })
            $text = ('{0} · {1}{2} · {3:N0} ms' -f $id.ip, $cn, $(if ($id.asn) { ' · AS' + $id.asn } else { '' }), [double]$id.ms)
            $color = $(if ($good) { '#15803D' } else { '#DC2626' }); $kind = $(if ($good) { 'Info' } else { 'Error' })
        } else {
            $title = '出口检查失败'
            $err = [string]$pr.error; if (-not $err) { $err = '没有拿到结果' }
            $text = ('{0}（不影响当前放行；守护 1 分钟后自动重试）' -f $err)
            $color = '#DC2626'; $kind = 'Warning'
        }
    } elseif ($st -and $st.switching) {
        if ($wait -lt 300) { $btnProbe.Content = '切换中…'; Set-ProbeMsg '正在热切换，切换完成后自动检查' '#B45309'; return }
    } elseif ($wait -lt 75) {
        $btnProbe.Content = $(if ($pr -and $pr.running) { '正在检查…' } else { '等待守护…' })
        return
    }
    if (-not $title) { $title = '出口检查没有回应'; $text = '守护在 75 秒内没有返回结果，请到「日志」查看。'; $color = '#B45309'; $kind = 'Warning' }
    $script:probeAsk = $null
    $btnProbe.Content = '立即检查出口'; $btnProbe.IsEnabled = ($script:status -and $script:status.key -ne 'off')
    Set-ProbeMsg ('{0}：{1}' -f $title, $text) $color
    $script:probeMsgUntil = (Get-Date).AddSeconds(60)
    if ($a.tray -or -not $win.IsVisible) { Show-Notice $title $text $kind }
}

function Send-GuardCommand([string]$cmd) {
    # 每条指令一个独立文件（cmd.<id>.json），先写 .tmp 再改名：守护读到的一定是完整文件，连续两条指令也不会互相覆盖
    try {
        if (-not [IO.Directory]::Exists($CmdDir)) { throw '守护服务尚未安装' }
        $id = [Guid]::NewGuid().ToString('N')
        $tmp = Join-Path $CmdDir ('cmd.' + $id + '.tmp')
        [IO.File]::WriteAllText($tmp, (@{ cmd = $cmd; ts = (Get-Date).ToString('o') } | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
        $gv = [version]'0.0'; try { $gv = [version][string]$script:snap.st.version } catch {}
        if ($gv -ge [version]'6.2') { [IO.File]::Move($tmp, (Join-Path $CmdDir ('cmd.' + $id + '.json'))) }
        else { Move-Item -LiteralPath $tmp -Destination (Join-Path $CmdDir 'cmd.json') -Force }   # 旧版守护只认 cmd.json
        return $true
    } catch {
        [System.Windows.MessageBox]::Show("操作失败：$($_.Exception.Message)", 'Claude 保护', 'OK', 'Warning') | Out-Null
        return $false
    }
}

function Set-AutoStart([bool]$On) {
    try {
        if ($On) {
            $wsh = New-Object -ComObject WScript.Shell
            $sc = $wsh.CreateShortcut($StartupLnk)
            $sc.TargetPath = Join-Path $env:windir 'System32\wscript.exe'
            $sc.Arguments = ('"{0}" -Tray' -f $Launcher)
            $sc.Description = 'Claude 保护（后台托盘）'
            $sc.Save()
        } else { Remove-Item -LiteralPath $StartupLnk -Force -ErrorAction SilentlyContinue }
    } catch {}
    $chkAuto.IsChecked = (Test-Path -LiteralPath $StartupLnk)
    if ($script:miAuto) { $script:miAuto.Checked = [bool]$chkAuto.IsChecked }
}

function Confirm-TurnOff {
    if ($script:snap -and $script:snap.es.builtin) {
        $coreLine = "`n· 内置内核停止（系统代理如有也会关掉）；电脑上的 Clash Verge / 白羊 App 不受影响"
    } else {
        $coreLine = "`n· Clash 会一并退出" + $(if ((Get-ConfigMode) -eq 'Strict') { "`n· Clash 配置恢复为白羊原始配置（全部节点 + 官方规则）" } else { '' })
    }
    $r = [System.Windows.MessageBox]::Show("关闭保护后：`n· 恢复普通网络，国内网站和软件正常使用$coreLine`n· Claude 不再受保护`n`n确定关闭吗？", 'Claude 保护', 'YesNo', 'Question')
    return ($r -eq 'Yes')
}
function Toggle-FromUi {
    if (-not $script:status) { return }
    if ($script:status.key -eq 'off') { Invoke-Toggle $true }
    elseif (Confirm-TurnOff) { Invoke-Toggle $false }
}

# ================================================================= 渲染入口（只用后台采集好的快照，不做任何慢操作）
function Render($s) {
    if (-not $s) { return }
    $script:snap = $s
    Test-BusyDone $s
    $sig = '{0}|{1}|{2}|{3}|{4}|{5}' -f $s.stSig, $s.alive, [bool]$script:busy, $s.es.engine, $s.es.netMode, $s.pin.name
    if ($sig -ne $script:lastViewSig) {
        $script:lastViewSig = $sig
        Update-View $s
        Invoke-Notify $s
    }
    Update-Busy $s
    Test-ProbeDone $s
    Update-Modes $s
    Update-Tray
    Test-SubDone $s
    Test-AutoSub $s
    Update-UpdateBadge $s
    if (-not $win.IsVisible -and -not $SelfTest) { return }
    switch ($script:page) {
        'overview' { Update-Tiles $s; Update-OverviewKV $s; Update-Events $s }
        'config'   { Update-CfgPanel $s; Update-PinPanel $s }
        'network'  { Update-NetworkPage $s }
        'procs'    { Update-ProcsPage $s }
        'logs'     { Update-Events $s }
        'maint'    { Update-VerPanel $s }
    }
    if ($script:page -ne 'overview') { Update-Events $s }
}

function Show-Page([string]$name) {
    $script:page = $name
    if ($name -eq 'network') { $sync.forceNet = $true }
    if ($name -eq 'procs') { $sync.forceProcs = $true }
    if ($name -eq 'conns' -and $nm) { $nm.visible = $true; $nm.wake = $true; $script:nmSeq = -1; Update-ConnPage }
    if ($name -eq 'corelog' -and $nm) { Update-LogFeed }
    $sync.page = $name; $sync.wake = $true
    foreach ($k in $Pages.Keys) { $Pages[$k].page.Visibility = $(if ($k -eq $name) { 'Visible' } else { 'Collapsed' }) }
    if (-not $Pages[$name].nav.IsChecked) { $Pages[$name].nav.IsChecked = $true }
    $hdrTitle.Text = $Pages[$name].title; $hdrSub.Text = $Pages[$name].sub
    if ($name -eq 'logs') { Update-LogPage }
    if ($name -eq 'network') { $sync.forceNet = $true }
    if ($name -eq 'procs') { $sync.forceProcs = $true }
    if ($name -eq 'maint') { $sync.reqUpdate = $true }
    if ($script:snap) { Render $script:snap }
}

function Show-Main {
    $win.Show(); $win.WindowState = 'Normal'; [void]$win.Activate()
    $win.Topmost = $true; $win.Topmost = $false
    $sync.visible = $true; $sync.wake = $true
    $script:lastViewSig = ''
    if ($script:snap) { Render $script:snap }
}


# ================================================================= 连接 / 内核日志（与 Clash Verge 的「连接」「日志」相同的信息）
# 后台两个线程（NetMonitor.ps1）：一个每秒读连接表并反查进程，一个订阅内核实时日志。界面线程只把结果写进 DataTable，
# 表格开启行虚拟化，只更新有变化的单元格，几百条连接、几千行日志也不会卡。
$script:nmMod = $(if ($script:ModDir) { Join-Path $script:ModDir 'NetMonitor.ps1' } else { '' })
$nm = $null
if ($script:nmMod -and (Test-Path -LiteralPath $script:nmMod)) { try { . $script:nmMod; $nm = New-NMState } catch { $nm = $null } }
$script:nmRs = @{}; $script:nmSeq = -1; $script:connPaused = $false; $script:logPaused = $false; $script:hubStart = Get-Date

function Start-NMWorker([string]$w) {
    $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'MTA'; $rs.Open()
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript('param($nm, $mod, $w, $gen) . $mod; if ($w -eq "conn") { Initialize-NMTypes; Invoke-NMConnLoop $nm $gen } else { Initialize-NMTypes -NoSock; Invoke-NMLogLoop $nm $gen }').AddArgument($nm).AddArgument($script:nmMod).AddArgument($w).AddArgument([int]$nm.gen)
    $script:nmRs[$w] = @{ ps = $ps; rs = $rs; h = $ps.BeginInvoke(); at = Get-Date }
}
function Test-NetMon {
    # 启动 3 秒后再开（不拖慢控制台启动）；线程意外退出 10 秒后重开
    if (-not $nm) { return }
    if (-not $SelfTest -and ((Get-Date) - $script:hubStart).TotalSeconds -lt 3) { return }
    foreach ($w in 'conn', 'log') {
        $x = $script:nmRs[$w]
        if (-not $x) { Start-NMWorker $w; continue }
        if ($x.h.IsCompleted -and ((Get-Date) - $x.at).TotalSeconds -gt 10) {
            try { $e = @($x.ps.Streams.Error | Select-Object -First 1); if ($e) { $nm.status = '连接监视线程重启：' + $e[0].ToString() } } catch {}
            try { $x.ps.Dispose(); $x.rs.Dispose() } catch {}
            Start-NMWorker $w
        }
    }
}

function Stop-NetMon {
    # 退出时：通知线程停止，并关掉正在阻塞读取的日志流（关闭连接会让阻塞的读取立刻返回）
    if (-not $nm) { return }
    $nm.stop = $true
    try { $r = $nm.curLog; if ($r) { Close-NMRequest $r } } catch {}
}

function New-Dt([string[]]$str, [string[]]$num, [string]$key) {
    $t = New-Object System.Data.DataTable
    foreach ($c in $str) { [void]$t.Columns.Add($c, [string]) }
    foreach ($c in $num) { [void]$t.Columns.Add($c, [double]) }
    if ($key) { $t.PrimaryKey = [System.Data.DataColumn[]]@($t.Columns[$key]) }
    return , $t   # 逗号：防止 PowerShell 把 DataTable 当集合展开（空表会变成 $null）
}
$dtConn   = New-Dt @('id', 'proc', 'dest', 'net', 'rule', 'chain', 'dlsT', 'ulsT', 'dlT', 'ulT', 'durT') @('dls', 'uls', 'dl', 'ul', 'start') 'id'
$dtClosed = New-Dt @('id', 'proc', 'dest', 'rule', 'chain', 'dlT', 'ulT', 'durT', 'endT', 'reason') @('dl', 'ul', 'durS', 'endTicks') ''
$dtLog    = New-Dt @('time', 'lv', 'lvT', 'msg') @('seq', 'lvn') ''
$dtClosed.DefaultView.Sort = 'endTicks DESC'
$dtLog.DefaultView.Sort = 'seq DESC'
$gridConns.ItemsSource = $dtConn.DefaultView
$gridClosed.ItemsSource = $dtClosed.DefaultView
$gridLog.ItemsSource = $dtLog.DefaultView

function ConvertTo-LikeText([string]$s) {
    $s = $s -replace "'", "''"
    return [regex]::Replace($s, '[\[\]\*%]', { param($m) '[' + $m.Value + ']' })
}
function Set-ConnFilter {
    $q = $cnSearch.Text.Trim()
    $cnSearchHint.Visibility = $(if ($cnSearch.Text) { 'Collapsed' } else { 'Visible' })
    $f = ''
    if ($q) { $e = ConvertTo-LikeText $q; $f = "proc LIKE '*{0}*' OR dest LIKE '*{0}*' OR rule LIKE '*{0}*' OR chain LIKE '*{0}*'" -f $e }
    try { $dtConn.DefaultView.RowFilter = $f; $dtClosed.DefaultView.RowFilter = $(if ($f) { $f + (" OR reason LIKE '*{0}*'" -f $e) } else { '' }) } catch {}
}
function Set-LogFilter {
    $clSearchHint.Visibility = $(if ($clSearch.Text) { 'Collapsed' } else { 'Visible' })
    $min = $(if ($lvErr.IsChecked) { 3 } elseif ($lvWarn.IsChecked) { 2 } else { 0 })
    $f = 'lvn >= ' + $min
    $q = $clSearch.Text.Trim()
    if ($q) { $f += " AND msg LIKE '*{0}*'" -f (ConvertTo-LikeText $q) }
    try { $dtLog.DefaultView.RowFilter = $f } catch {}
}

function Update-ConnPage {
    if (-not $nm) { $cnSummary.Text = '缺少 NetMonitor.ps1，请在「维护」里更新到最新版'; return }
    $seq = [int]$nm.connSeq
    if ($seq -ne $script:nmSeq -and -not $script:connPaused) {
        $script:nmSeq = $seq
        $rows = @($nm.conns)
        $seen = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($r in $rows) {
            [void]$seen.Add([string]$r.id)
            $row = $dtConn.Rows.Find($r.id)
            if (-not $row) {
                $row = $dtConn.NewRow()
                foreach ($k in @('id', 'proc', 'dest', 'net', 'rule', 'chain', 'dlsT', 'ulsT', 'dlT', 'ulT', 'durT', 'dls', 'uls', 'dl', 'ul', 'start')) { $row[$k] = $r[$k] }
                $dtConn.Rows.Add($row)
            } else {
                if ([double]$row['dl'] -ne [double]$r.dl) { $row['dl'] = $r.dl; $row['dlT'] = $r.dlT }
                if ([double]$row['ul'] -ne [double]$r.ul) { $row['ul'] = $r.ul; $row['ulT'] = $r.ulT }
                if ([string]$row['dlsT'] -ne $r.dlsT) { $row['dls'] = $r.dls; $row['dlsT'] = $r.dlsT }
                if ([string]$row['ulsT'] -ne $r.ulsT) { $row['uls'] = $r.uls; $row['ulsT'] = $r.ulsT }
                if ([string]$row['durT'] -ne $r.durT) { $row['durT'] = $r.durT }
            }
        }
        for ($i = $dtConn.Rows.Count - 1; $i -ge 0; $i--) { if (-not $seen.Contains([string]$dtConn.Rows[$i]['id'])) { $dtConn.Rows.RemoveAt($i) } }
        $tot = $nm.totals
        if ($nm.status) { $cnSummary.Text = '无法读取连接：' + $nm.status; $cnSummary.Foreground = B '#B45309' }
        elseif ($tot) {
            $cnSummary.Text = ('{0} · {1} 个连接 · 当前 ↓ {2}/s  ↑ {3}/s · 内核启动以来 ↓ {4}  ↑ {5}' -f $nm.label, $rows.Count, (Format-NMBytes $tot.sd), (Format-NMBytes $tot.su), (Format-NMBytes $tot.down), (Format-NMBytes $tot.up))
            $cnSummary.Foreground = B '#334155'
        }
        $cnTop.Text = $(if ($nm.top) { '谁在用网：' + $nm.top } else { '' })
        if ($script:connPaused) { $cnSummary.Text = '已暂停刷新 · ' + $cnSummary.Text }
    }
    $e = $null; $n = 0
    while ($n -lt 300 -and $nm.closedQ.TryDequeue([ref]$e)) {
        $row = $dtClosed.NewRow()
        foreach ($k in @('id', 'proc', 'dest', 'rule', 'chain', 'dlT', 'ulT', 'durT', 'endT', 'reason', 'dl', 'ul', 'durS', 'endTicks')) { $row[$k] = $e[$k] }
        $dtClosed.Rows.Add($row); $n++
    }
    if ($dtClosed.Rows.Count -gt 1000) { for ($i = $dtClosed.Rows.Count - 900; $i -gt 0; $i--) { $dtClosed.Rows.RemoveAt(0) } }
    $cnActive.Content = '活动 {0}' -f $dtConn.Rows.Count
    $cnClosed.Content = '已关闭 {0}' -f $dtClosed.Rows.Count
}

function Update-LogFeed {
    if (-not $nm) { return }
    if (-not $script:logPaused) {
        $e = $null; $n = 0
        while ($n -lt 300 -and $nm.logQ.TryDequeue([ref]$e)) {
            $row = $dtLog.NewRow()
            $row['seq'] = [double]$e.seq; $row['time'] = ([DateTime]$e.t).ToString('HH:mm:ss'); $row['lv'] = [string]$e.lv; $row['msg'] = [string]$e.msg
            switch ([string]$e.lv) { 'error' { $row['lvn'] = 3; $row['lvT'] = '错误' } 'warning' { $row['lvn'] = 2; $row['lvT'] = '警告' } 'info' { $row['lvn'] = 1; $row['lvT'] = '信息' } default { $row['lvn'] = 0; $row['lvT'] = '调试' } }
            $dtLog.Rows.Add($row); $n++
        }
        if ($dtLog.Rows.Count -gt 5000) { for ($i = $dtLog.Rows.Count - 4500; $i -gt 0; $i--) { $dtLog.Rows.RemoveAt(0) } }
    }
    if ($script:page -eq 'corelog') {
        $st = $(if ($nm.logLabel) { '已连接 ' + $nm.logLabel + ' 的实时日志' } elseif ($nm.logStatus) { '未连接：' + $nm.logStatus } else { '正在连接内核日志…' })
        $pend = $(if ($script:logPaused) { ' · 已暂停（{0} 条新日志待显示）' -f $nm.logQ.Count } else { '' })
        $clSummary.Text = ('{0} · 共 {1} 条（显示 {2} 条）{3}' -f $st, $dtLog.Rows.Count, $dtLog.DefaultView.Count, $pend)
    }
}

function Close-SelectedConns {
    if (-not $nm) { return }
    $ids = @($gridConns.SelectedItems | ForEach-Object { [string]$_['id'] })
    if ($ids.Count -eq 0) { return }
    foreach ($i in $ids) { $nm.closeQ.Enqueue($i) }
    $nm.wake = $true
}
function Copy-GridRows($grid, [string[]]$cols, [int]$max = 500) {
    $items = @($grid.SelectedItems)
    if ($items.Count -eq 0) { $items = @($grid.ItemsSource | Select-Object -First $max) }
    $lines = foreach ($it in $items) { ($cols | ForEach-Object { [string]$it[$_] }) -join '  ' }
    try { [System.Windows.Clipboard]::SetText(($lines -join "`r`n")) } catch {}
}
function New-GridMenu($items) {
    $cm = New-Object System.Windows.Controls.ContextMenu
    foreach ($x in $items) { $mi = New-Object System.Windows.Controls.MenuItem; $mi.Header = $x[0]; $mi.Add_Click($x[1]); [void]$cm.Items.Add($mi) }
    return $cm
}
$gridConns.ContextMenu = New-GridMenu @(
    @('关闭此连接', { Close-SelectedConns }),
    @('复制目标地址', { Copy-GridRows $gridConns @('dest') }),
    @('复制整行', { Copy-GridRows $gridConns @('proc', 'dest', 'net', 'rule', 'chain', 'dlT', 'ulT', 'durT') }))
$gridClosed.ContextMenu = New-GridMenu @(,@('复制整行', { Copy-GridRows $gridClosed @('endT', 'proc', 'dest', 'chain', 'dlT', 'ulT', 'durT', 'reason') }))
$gridLog.ContextMenu = New-GridMenu @(,@('复制选中的日志', { Copy-GridRows $gridLog @('time', 'lvT', 'msg') }))

$cnActive.Add_Checked({ $gridConns.Visibility = 'Visible'; $gridClosed.Visibility = 'Collapsed' })
$cnClosed.Add_Checked({ $gridConns.Visibility = 'Collapsed'; $gridClosed.Visibility = 'Visible' })
$cnSearch.Add_TextChanged({ Set-ConnFilter })
$clSearch.Add_TextChanged({ Set-LogFilter })
foreach ($rb in @($lvAll, $lvWarn, $lvErr)) { $rb.Add_Checked({ Set-LogFilter }) }
Set-LogFilter
$btnConnClose.Add_Click({ Close-SelectedConns })
$btnConnCloseAll.Add_Click({
    if (-not $nm -or $dtConn.Rows.Count -eq 0) { return }
    $r = [System.Windows.MessageBox]::Show(("关闭全部 {0} 个连接？`n`n正在进行的下载、Claude 正在输出的回复会中断，程序一般会自动重新连接。" -f $dtConn.Rows.Count), 'Claude 保护', 'YesNo', 'Question')
    if ($r -eq 'Yes') { $nm.closeQ.Enqueue('*'); $nm.wake = $true }
})
$btnConnPause.Add_Click({
    $script:connPaused = -not $script:connPaused
    $btnConnPause.Content = $(if ($script:connPaused) { '继续' } else { '暂停' }); $btnConnPause.Tag = [string][char]$(if ($script:connPaused) { 0xE768 } else { 0xE769 })
    $script:nmSeq = -1
})
$btnLogPause.Add_Click({
    $script:logPaused = -not $script:logPaused
    $btnLogPause.Content = $(if ($script:logPaused) { '继续' } else { '暂停' }); $btnLogPause.Tag = [string][char]$(if ($script:logPaused) { 0xE768 } else { 0xE769 })
})
$btnLogClear.Add_Click({ $dtLog.Rows.Clear() })
$btnLogCopy.Add_Click({ Copy-GridRows $gridLog @('time', 'lvT', 'msg') 2000; $btnLogCopy.Content = '已复制'; $script:logCopyReset = (Get-Date).AddSeconds(2) })

# ================================================================= 事件绑定
foreach ($k in $Pages.Keys) {
    $Pages[$k].nav.Add_Checked({ param($sd, $e) foreach ($kk in $Pages.Keys) { if ([object]::ReferenceEquals($Pages[$kk].nav, $sd) -and $script:page -ne $kk) { Show-Page $kk } } })
}
$btnMain.Add_Click({ Toggle-FromUi })
$btnProbe.Add_Click({ Start-ProbeCheck })
$btnAllLogs.Add_Click({ Show-Page 'logs' })
$btnGoConfig.Add_Click({ Show-Page 'config' })
$btnTest.Add_Click({ Start-ConnTest })
$btnForce.Add_Click({
    $forced = [bool]($script:snap -and $script:snap.st -and $script:snap.st.forced)
    if ($forced) { [void](Send-GuardCommand 'force-unlock') }
    else {
        $r = [System.Windows.MessageBox]::Show('强制断网会让整台电脑立即断网，直到你点「取消强制断网」。确定吗？', 'Claude 保护', 'YesNo', 'Warning')
        if ($r -eq 'Yes') { [void](Send-GuardCommand 'force-lock') }
    }
})
$btnLog.Add_Click({ if (Test-Path -LiteralPath $LogFile) { Start-Process notepad.exe -ArgumentList "`"$LogFile`"" } })
$btnCopy.Add_Click({
    try {
        $diag = [ordered]@{ hub = $HubVersion; time = (Get-Date).ToString('o'); configMode = (Get-ConfigMode) }
        if ($script:snap) { $diag.engine = $script:snap.es.engine; $diag.netMode = $script:snap.es.netMode; $diag.source = $script:snap.es.source; $diag.clashConfig = $script:snap.vmode; $diag.collectorErr = $sync.err }
        $txt = ($diag | ConvertTo-Json) + "`r`n" + (Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8)
        [System.Windows.Clipboard]::SetText($txt); $btnCopy.Content = '已复制'; $script:copyBtnReset = (Get-Date).AddSeconds(3)
    } catch {}
})
$btnRescue.Add_Click({ Start-RescueFromUi })
$btnUpdate.Add_Click({ Invoke-SelfUpdate })
$btnRepair.Add_Click({ Invoke-Repair })
$btnSub.Add_Click({ Start-SubRefresh $false })
$btnPin.Add_Click({ Invoke-PinNode })
$mTun.Add_Click({ Invoke-ModeClick 'tun' });   $cTun.Add_Click({ Invoke-ModeClick 'tun' })
$mSys.Add_Click({ Invoke-ModeClick 'sys' });   $cSys.Add_Click({ Invoke-ModeClick 'sys' })
$mVerge.Add_Click({ Invoke-ModeClick 'verge' }); $cVerge.Add_Click({ Invoke-ModeClick 'verge' })
$btnKillConflict.Add_Click({ Invoke-KillConflicts })
$btnImport.Add_Click({ Invoke-ImportLocal })
$rbSrcBaiyang.Add_Checked({ Set-SourceChoice 'baiyang' })
$rbSrcLocal.Add_Checked({ Set-SourceChoice 'local' })
$btnRollback.Add_Click({ Invoke-Rollback })
$cbNodes.Add_SelectionChanged({ if (-not $script:fillingNodes) { Update-PinHint } })
$btnKill.Add_Click({ Invoke-KillClaude })
$btnProcRefresh.Add_Click({ $sync.forceProcs = $true; $sync.wake = $true })
$chkWarnOnly.Add_Click({ Update-LogPage })
$chkAuto.Add_Click({ Set-AutoStart ([bool]$chkAuto.IsChecked) })
if ((Get-ConfigMode) -eq 'Strict') { $rbStrict.IsChecked = $true } else { $rbKeep.IsChecked = $true }
$rbStrict.Add_Checked({ Save-Setting 'configSwitch' $true })
$rbKeep.Add_Checked({ Save-Setting 'configSwitch' $false })
$hdrTitle.Text = $Pages['overview'].title; $hdrSub.Text = $Pages['overview'].sub

# ================================================================= 自检（渲染各页面截图）
if ($SelfTest) {
    Start-Collector
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sync.seq -lt 2 -and $sw.Elapsed.TotalSeconds -lt 30) { Start-Sleep -Milliseconds 200 }
    $s = $sync.snap
    Write-Host ("COLLECTOR  seq={0}  first={1:N1}s  err={2}  bp={3} bc={4}" -f $sync.seq, $sw.Elapsed.TotalSeconds, $sync.err, $s.bp, $s.bc)
    $times = @{}
    foreach ($pg in @($Pages.Keys)) {
        $script:page = $pg
        $t = [Diagnostics.Stopwatch]::StartNew(); $script:lastViewSig = ''; Render $s; $times[$pg] = [int]$t.ElapsedMilliseconds
    }
    Update-LogPage
    Write-Host ("RENDER ms  " + (($times.GetEnumerator() | Sort-Object Name | ForEach-Object { '{0}={1}' -f $_.Name, $_.Value }) -join '  '))
    $times2 = @{}
    foreach ($pg in @($Pages.Keys)) { $script:page = $pg; $t = [Diagnostics.Stopwatch]::StartNew(); Render $s; $times2[$pg] = [int]$t.ElapsedMilliseconds }
    Write-Host ("STEADY ms  " + (($times2.GetEnumerator() | Sort-Object Name | ForEach-Object { '{0}={1}' -f $_.Name, $_.Value }) -join '  '))
    $col = @(); for ($i = 0; $i -lt 5; $i++) { $q = $sync.seq; $t = [Diagnostics.Stopwatch]::StartNew(); $sync.wake = $true; while ($sync.seq -eq $q -and $t.ElapsedMilliseconds -lt 5000) { Start-Sleep -Milliseconds 20 }; $col += [int]$t.ElapsedMilliseconds }
    Write-Host ("COLLECT ms (background, per cycle)  " + ($col -join ' '))
    $es = $s.es
    Write-Host ("ENGINE  engine={0}  netMode={1}  source={2}  want={3}/{4}/{5}  conflicts={6}  versions={7}  proxy={8}" -f $es.engine, $es.netMode, $es.source, $es.wantEngine, $es.wantNetMode, $es.wantSource, @($s.conf).Count, @($s.versions).Count, $s.px.server)
    Write-Host ("STATUS  key={0}  title={1}  checks={2}  events={3}  logs={4}  procs={5}  nodes={6}  core={7}  rules={8}" -f $script:status.key, $script:status.title, $panelChecks.Children.Count, $panelEvents.Children.Count, @($s.logs).Count, @($s.procs).Count, @($s.sub.nodes).Count, $s.coreVer, $s.ruleVer)
    Write-Host ("TILES  ip={0} | {1} | lat={2} | speed={3} {4} | quota={5} | {6}" -f $tIp.Text, $tIpSub.Text, $tLat.Text, $tSpeed.Text, $tSpeedSub.Text, $tQuota.Text, $tQuotaSub.Text)
    Write-Host ("MODES  tun={0} sys={1} verge={2}  hint={3}  update={4}" -f $mTun.IsChecked, $mSys.IsChecked, $mVerge.IsChecked, $modeHint.Text, (@($s.update.changed) -join ','))
    $script:page = 'network'; Render $sync.snap
    Write-Host ("NETWORK  stamp={0}  core={1}  tun={2}" -f $netStamp.Text, $titCore.Text, $titTun.Text)
    $fake = $sync.snap.net; $old = [ordered]@{}; foreach ($k in $fake.Keys) { $old[$k] = $fake[$k] }; $old.engine = 'builtin'
    $s2 = @{}; foreach ($k in $sync.snap.Keys) { $s2[$k] = $sync.snap[$k] }; $s2.net = $old
    $kvCore.Tag = ''; Update-NetworkPage $s2
    Write-Host ("NETWORK(other engine data)  stamp={0}  rows={1}" -f $netStamp.Text, $kvCore.Children.Count)
    if ($nm) {
        $nm.visible = $true; Test-NetMon
        $w = [Diagnostics.Stopwatch]::StartNew()
        while (($nm.connSeq -lt 3 -or $nm.logQ.Count -eq 0) -and $w.Elapsed.TotalSeconds -lt 20) { Start-Sleep -Milliseconds 200 }
        $script:page = 'conns'
        $t1 = [Diagnostics.Stopwatch]::StartNew(); $script:nmSeq = -1; Update-ConnPage; $ms1 = $t1.ElapsedMilliseconds
        Start-Sleep -Milliseconds 1200
        $t1.Restart(); Update-ConnPage; $ms2 = $t1.ElapsedMilliseconds
        $script:page = 'corelog'
        $t1.Restart(); Update-LogFeed; $ms3 = $t1.ElapsedMilliseconds
        Write-Host ("CONNS  label={0} rows={1} closed={2} first={3}ms update={4}ms  summary={5}" -f $nm.label, $dtConn.Rows.Count, $dtClosed.Rows.Count, $ms1, $ms2, $cnSummary.Text)
        Write-Host ("CONNS  top={0}" -f $cnTop.Text)
        Write-Host ("CORELOG rows={0} feed={1}ms  summary={2}" -f $dtLog.Rows.Count, $ms3, $clSummary.Text)
        $cnSearch.Text = 'claude'; Write-Host ("FILTER 'claude' -> {0} rows" -f $dtConn.DefaultView.Count); $cnSearch.Text = ''
        $lvWarn.IsChecked = $true; Write-Host ("LOG warn+ -> {0} rows" -f $dtLog.DefaultView.Count); $lvAll.IsChecked = $true
        $nm.stop = $true
    }
    foreach ($k in $Palette.Keys) { [void](Get-Icon $k) }
    if ($env:HUB_SNAPSHOT) {
        $rootEl = $win.Content; $win.Content = $null
        $host2 = New-Object System.Windows.Controls.Border; $host2.Background = B '#F1F5F9'; $host2.Child = $rootEl
        [System.Windows.Documents.TextElement]::SetFontFamily($host2, $win.FontFamily); [System.Windows.Documents.TextElement]::SetFontSize($host2, $win.FontSize); [System.Windows.Documents.TextElement]::SetForeground($host2, $win.Foreground)
        $host2.Resources = $win.Resources
        $pagesToShoot = $(if ($env:HUB_SNAPSHOT_PAGES) { $env:HUB_SNAPSHOT_PAGES -split ',' } else { @($Pages.Keys) })
        foreach ($pg in $pagesToShoot) {
            $script:page = $pg
            foreach ($k in $Pages.Keys) { $Pages[$k].page.Visibility = $(if ($k -eq $pg) { 'Visible' } else { 'Collapsed' }); $Pages[$k].nav.IsChecked = ($k -eq $pg) }
            $hdrTitle.Text = $Pages[$pg].title; $hdrSub.Text = $Pages[$pg].sub
            Render $s; if ($pg -eq 'logs') { Update-LogPage }
            $W = 1100; $H = 800
            $host2.Measure((New-Object System.Windows.Size($W, $H))); $host2.Arrange((New-Object System.Windows.Rect(0, 0, $W, $H))); $host2.UpdateLayout()
            $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($W, $H, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
            $rtb.Render($host2)
            $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder; $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
            $out = $env:HUB_SNAPSHOT -replace '\.png$', ('-' + $pg + '.png')
            $fs = [IO.File]::Create($out); $enc.Save($fs); $fs.Close()
            Write-Host "SNAPSHOT $out"
        }
    }
    Stop-Collector
    return
}

# ================================================================= 托盘
$script:trayIcon = New-Object System.Windows.Forms.NotifyIcon
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miOpen   = $menu.Items.Add('打开 Claude 保护')
$miOpen.Font = New-Object System.Drawing.Font($miOpen.Font, [System.Drawing.FontStyle]::Bold)
$miNewUi  = $menu.Items.Add('新界面（流量统计 / 连接 / 规则）')
[void]$menu.Items.Add('-')
$script:miToggle = $menu.Items.Add('开启保护')
$miMode = New-Object System.Windows.Forms.ToolStripMenuItem('运行模式')
$script:miModes = [ordered]@{}
foreach ($mk in $ModeInfo.Keys) {
    $it = New-Object System.Windows.Forms.ToolStripMenuItem($ModeInfo[$mk].label)
    $it.Tag = $mk
    $it.Add_Click({ param($sd, $e) Show-Main; Invoke-ModeClick ([string]$sd.Tag) })
    [void]$miMode.DropDownItems.Add($it)
    $script:miModes[$mk] = $it
}
[void]$menu.Items.Add($miMode)
$script:miProbe  = $menu.Items.Add('立即检查出口')
$miSub    = $menu.Items.Add('更新订阅')
$miKill   = $menu.Items.Add('结束所有 Claude 程序')
$miRescue = $menu.Items.Add('应急恢复网络')
[void]$menu.Items.Add('-')
$script:miAuto   = New-Object System.Windows.Forms.ToolStripMenuItem('开机自动运行')
[void]$menu.Items.Add($script:miAuto)
$miExit   = $menu.Items.Add('退出')
$script:trayIcon.ContextMenuStrip = $menu
$script:trayIcon.Icon = Get-Icon 'off'
$script:trayIcon.Text = 'Claude 保护'
$script:trayIcon.Visible = $true

$miOpen.Add_Click({ Show-Main })
$miNewUi.Add_Click({
    $exe = Join-Path $Root 'bin\cg-hub.exe'
    if (Test-Path -LiteralPath $exe) { Start-Process -FilePath $exe }
    else { [System.Windows.MessageBox]::Show('新界面还没安装，请在「维护」里点「更新到最新版」。', 'Claude 保护') | Out-Null }
})
$script:miToggle.Add_Click({ Show-Main; Toggle-FromUi })
$script:miProbe.Add_Click({ Start-ProbeCheck -Tray })
$miSub.Add_Click({ Start-SubRefresh $false; Show-Notice '正在更新订阅' '完成后会通知你结果。' })
$miKill.Add_Click({ Show-Main; Show-Page 'procs'; Invoke-KillClaude })
$miRescue.Add_Click({ Start-RescueFromUi })
$script:miAuto.Add_Click({ Set-AutoStart (-not (Test-Path -LiteralPath $StartupLnk)) })
$script:trayIcon.Add_MouseClick({ param($sd, $e) if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Show-Main } })
$script:trayIcon.Add_BalloonTipClicked({ Show-Main })

$script:exiting = $false
$miExit.Add_Click({
    if ($script:status -and $script:status.key -ne 'off') {
        $r = [System.Windows.MessageBox]::Show("退出程序后保护仍会在后台继续。`n`n是：同时关闭保护（恢复普通网络）`n否：保持保护，只退出本程序`n取消：不退出", 'Claude 保护', 'YesNoCancel', 'Question')
        if ($r -eq 'Cancel') { return }
        if ($r -eq 'Yes') { Invoke-Toggle $false }
    }
    $script:exiting = $true
    $timer.Stop()
    Stop-Collector
    Stop-NetMon
    $script:trayIcon.Visible = $false; $script:trayIcon.Dispose()
    $win.Close()
    [System.Windows.Application]::Current.Shutdown()
})

$win.Add_Closing({
    param($sd, $e)
    if ($script:exiting) { return }
    $e.Cancel = $true
    $win.Hide()
    $sync.visible = $false
    if (-not $script:hiddenTipShown) {
        $script:hiddenTipShown = $true
        Show-Notice 'Claude 保护仍在运行' '已收到右下角托盘。点击图标可重新打开，右键可开启/关闭保护或切换运行模式。'
    }
})
$win.Add_StateChanged({ $sync.visible = ($win.IsVisible -and $win.WindowState -ne 'Minimized'); if ($sync.visible) { $sync.wake = $true } })

# 首次运行：默认开机自启
try {
    if (-not [bool](Get-Settings).firstRunDone -and (Test-Path -LiteralPath $Launcher)) {
        if (-not (Test-Path -LiteralPath $SettingsFile)) { Set-AutoStart $true }
        Save-Setting 'firstRunDone' $true
    }
} catch {}
$chkAuto.IsChecked = (Test-Path -LiteralPath $StartupLnk)

# ================================================================= 主循环：界面线程只看快照有没有更新，不做任何慢操作
Start-Collector
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(250)
$timer.Add_Tick({
    try {
        if ($script:showEvt.WaitOne(0)) { Show-Main }
        while ($sync.notices.Count -gt 0) { $n = $sync.notices[0]; $sync.notices.RemoveAt(0); Show-Notice $n[0] $n[1] $n[2] }
        $seq = [int]$sync.seq
        if ($seq -ne $script:lastSeq) {
            $script:lastSeq = $seq; $script:lastSeqAt = Get-Date
            $s = $sync.snap
            if ($s) {
                if (-not $script:firstRender) { $script:firstRender = $true; $script:prevKey = Get-StatusKey $s.st $s.alive }   # 启动时不弹通知，只对之后的变化通知
                Render $s
            }
        } elseif ($script:busy -and $script:snap) { Update-Busy $script:snap }
        # 采集线程意外退出，或卡住超过 30 秒（例如系统 WMI 无响应）：另起一个新的采集线程
        $stuck = ((([DateTime]::UtcNow) - [DateTime]$sync.beat).TotalSeconds -gt 30)
        if ($script:collector -and (((Get-Date) - $script:lastSeqAt).TotalSeconds -gt 20 -and $script:collector.handle.IsCompleted -or $stuck)) {
            $old = $script:collector
            if ($old.handle.IsCompleted) { try { $old.ps.Dispose(); $old.rs.Dispose() } catch {} }
            else { try { [void]$old.ps.BeginStop($null, $null) } catch {} }   # 卡住的线程不等它，异步停止
            $sync.stop = $false; Start-Collector; $script:lastSeqAt = Get-Date
        }
        Test-ConnTestDone
        Test-BgJobs
        if ($nm) {
            Test-NetMon
            $nm.visible = ($script:page -eq 'conns' -and [bool]$sync.visible)
            if ($script:page -eq 'conns') { Update-ConnPage }
            Update-LogFeed
            if ($script:logCopyReset -and (Get-Date) -gt $script:logCopyReset) { $btnLogCopy.Content = '复制'; $script:logCopyReset = $null }
        }
        if ($script:probeAsk -and $script:snap) { Test-ProbeDone $script:snap }
        elseif ($script:probeMsgUntil -and (Get-Date) -gt $script:probeMsgUntil) { Set-ProbeMsg '' ''; $script:probeMsgUntil = $null }
        if ($script:copyBtnReset -and (Get-Date) -gt $script:copyBtnReset) { $btnCopy.Content = '复制诊断信息'; $script:copyBtnReset = $null }
        if ($script:killBtnReset -and (Get-Date) -gt $script:killBtnReset) { $btnKill.Content = '结束所有 Claude 程序'; $script:killBtnReset = $null }
    } catch {}
})

$app = New-Object System.Windows.Application
$app.ShutdownMode = 'OnExplicitShutdown'
$timer.Start()
if (-not $Tray) { Show-Main }
[void]$app.Run()
# 后台线程（日志流读取可能正阻塞在管道上）不等它们，直接结束进程
try { Stop-NetMon } catch {}
[Environment]::Exit(0)
