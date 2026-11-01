using System;
using System.IO;
using System.Linq;

namespace SteveTransformation;

internal enum McItem { Empty, Sword, Shield, Bow, Tnt, Flint, Pearl, Arrow, Dirt, Stone, ZombieEgg, CreeperEgg, GoldenApple, Pickaxe, Totem, Trident, Boat, Piston, StickyPiston, Observer, EndRod, Lever, Redstone, RedstoneBlock, SheepMachine,
    Mace, MaceDensity, MaceBreach, MaceWindI, MaceWindII, MaceWindIII, MaceDensityWind, MaceBreachWind, WindCharge,
    WoodenSpear, StoneSpear, CopperSpear, IronSpear, GoldenSpear, DiamondSpear, NetheriteSpear,
    WoodenSpearLungeIII, StoneSpearLungeIII, CopperSpearLungeIII, IronSpearLungeIII, GoldenSpearLungeIII, DiamondSpearLungeIII, NetheriteSpearLungeIII,
    NetheriteSpearLungeI, NetheriteSpearLungeII,
    WoodenSword, StoneSword, CopperSword, IronSword, GoldenSword, NetheriteSword,
    WoodenPickaxe, StonePickaxe, CopperPickaxe, IronPickaxe, GoldenPickaxe, NetheritePickaxe,
    LeatherHelmet, LeatherChestplate, LeatherLeggings, LeatherBoots,
    CopperHelmet, CopperChestplate, CopperLeggings, CopperBoots,
    ChainmailHelmet, ChainmailChestplate, ChainmailLeggings, ChainmailBoots,
    IronHelmet, IronChestplate, IronLeggings, IronBoots,
    GoldenHelmet, GoldenChestplate, GoldenLeggings, GoldenBoots,
    DiamondHelmet, DiamondChestplate, DiamondLeggings, DiamondBoots,
    NetheriteHelmet, NetheriteChestplate, NetheriteLeggings, NetheriteBoots,
    LifeCrystal, LifeShard, HealingBottle, BottleCapacity, BottleStrength, PrizeTicket, LuckyClover }

internal sealed partial class MinecraftInventory
{
    internal readonly McItem[] Slots=new McItem[36];
    internal int Selected;
    internal McItem Carried;
    internal McItem Offhand=McItem.Shield;
    private string? path;
    private int carriedOrigin=-1;
    internal static readonly McItem[] Catalog=Enum.GetValues(typeof(McItem)).Cast<McItem>().Where(i=>i!=McItem.Empty && i<=McItem.NetheriteSpearLungeII).ToArray();
    internal McItem Held => Slots[Selected];
    internal MinecraftInventory()
    {
        var items=new[]{McItem.Sword,McItem.Bow,McItem.Tnt,McItem.Flint,McItem.Pearl,McItem.Shield,McItem.Arrow};
        Array.Copy(items,Slots,items.Length);
        Array.Copy(items,0,Slots,9,items.Length);
        GrantNewItems();
    }
    private void GrantNewItems()
    {
        foreach(var item in new[]{McItem.Dirt,McItem.Stone,McItem.ZombieEgg,McItem.CreeperEgg,McItem.GoldenApple,McItem.Pickaxe,McItem.Totem,McItem.Trident,McItem.Boat,McItem.Piston,McItem.StickyPiston,McItem.Observer,McItem.EndRod,McItem.Lever,McItem.Redstone,McItem.RedstoneBlock,McItem.SheepMachine,McItem.Mace,McItem.WindCharge,McItem.DiamondSpear})
            if(!Slots.Contains(item) && Offhand!=item)
                for(int i=9;i<Slots.Length;i++) if(Slots[i]==McItem.Empty) {Slots[i]=item;break;}
    }
    internal void Select(int slot) { Selected=(slot%9+9)%9;if(Adventure!=null) {Adventure.Data.Selected=Selected;Adventure.Changed();} }
    internal int TakeCatalog(McItem item)
    {
        if(Adventure!=null) return -1;
        Close();
        int slot=Array.IndexOf(Slots,McItem.Empty);
        if(Carried!=McItem.Empty || item==McItem.Empty || slot<0) return -1;
        Slots[slot]=item;Click(slot);return slot;
    }
    internal void ReturnToCatalog() {if(Adventure!=null) {Close();return;}Carried=McItem.Empty;carriedOrigin=-1;}
    internal void Click(int slot)
    {
        if(Adventure!=null) {AdventureClick(slot);return;}
        if(slot<0 || slot>=Slots.Length) return;
        if(Carried==McItem.Empty && Slots[slot]!=McItem.Empty) carriedOrigin=slot;
        var item=Slots[slot];Slots[slot]=Carried;Carried=item;
        if(Carried==McItem.Empty) carriedOrigin=-1;
    }
    internal void ClickOffhand()
    {
        if(Adventure!=null) {AdventureClick(36);return;}
        if(Carried==McItem.Empty && Offhand!=McItem.Empty) carriedOrigin=36;
        var item=Offhand;Offhand=Carried;Carried=item;
        if(Carried==McItem.Empty) carriedOrigin=-1;
    }
    internal void Drop(int source,int destination)
    {
        if(Adventure!=null) {AdventureDrop(source,destination);return;}
        if(source<0 || source>36 || Carried==McItem.Empty) return;
        if(destination>=0 && destination<=36)
        {
            if(destination==36) ClickOffhand();else Click(destination);
        }
        // A drag swaps the displaced item back to the pickup slot; a click may keep it on the cursor.
        if(Carried!=McItem.Empty && (source==36?Offhand:Slots[source])==McItem.Empty)
        {
            if(source==36) Offhand=Carried;else Slots[source]=Carried;
            Carried=McItem.Empty;carriedOrigin=-1;
        }
    }
    internal void Close()
    {
        if(Adventure!=null) {AdventureClose();return;}
        if(Carried==McItem.Empty) return;
        if(carriedOrigin>=0 && (carriedOrigin==36?Offhand:Slots[carriedOrigin])==McItem.Empty)
        {
            if(carriedOrigin==36) Offhand=Carried;else Slots[carriedOrigin]=Carried;
            Carried=McItem.Empty;carriedOrigin=-1;return;
        }
        int free=Array.IndexOf(Slots,McItem.Empty);
        if(free>=0) {Slots[free]=Carried;Carried=McItem.Empty;}
        else if(Offhand==McItem.Empty) {Offhand=Carried;Carried=McItem.Empty;}
    }
    internal void Configure(string layoutPath)
    {
        path=null;
        if(File.Exists(layoutPath))
        {
            var tokens=File.ReadAllText(layoutPath).Split(',');
            if(tokens.Length!=39 || !int.TryParse(tokens[0],out int version) || version<1 || version>5 || !int.TryParse(tokens[1],out int selected) || selected<0 || selected>=9) return;
            var items=new McItem[37];
            for(int i=0;i<items.Length;i++)
            {
                if(!int.TryParse(tokens[i+2],out int value)||value<0||value>(int)McItem.NetheriteSpearLungeII) return;
                items[i]=(McItem)value;
            }
            Selected=selected;Array.Copy(items,Slots,36);Offhand=items[36];
            if(version<5) GrantNewItems();
        }
        path=layoutPath;
    }
    internal void Save()
    {
        if(Adventure!=null) {Close();Adventure.Save();return;}
        if(path==null) return;
        Close();
        string contents="5,"+Selected+","+string.Join(",",Slots.Concat(new[]{Offhand}).Select(i=>(int)i));
        string temp=path+"."+Guid.NewGuid().ToString("N")+".tmp";
        File.WriteAllText(temp,contents);
        if(File.Exists(path)) File.Replace(temp,path,null);else File.Move(temp,path);
    }
    internal static string Asset(McItem item) => item switch
    {
        _ when AdventureItems.Asset(item)!=null=>AdventureItems.Asset(item)!,
        _ when MinecraftWeapons.IsMace(item)=>"mace",
        McItem.WindCharge=>"wind_charge",
        _ when MinecraftWeapons.IsSpear(item)=>new[]{"wooden","stone","copper","iron","golden","diamond","netherite"}[MinecraftWeapons.Material(item)]+"_spear",
        McItem.Sword=>"diamond_sword",McItem.Shield=>"shield",McItem.Bow=>"bow",McItem.Tnt=>"tnt",
        McItem.Flint=>"flint_and_steel",McItem.Pearl=>"ender_pearl",McItem.Arrow=>"arrow",
        McItem.Dirt=>"dirt",McItem.Stone=>"stone",McItem.ZombieEgg=>"zombie_spawn_egg",McItem.CreeperEgg=>"creeper_spawn_egg",
        McItem.GoldenApple=>"golden_apple",McItem.Pickaxe=>"diamond_pickaxe",McItem.Totem=>"totem_of_undying",McItem.Trident=>"trident",
        McItem.Boat=>"oak_boat",McItem.Piston=>"piston",McItem.StickyPiston=>"sticky_piston",McItem.Observer=>"observer",McItem.EndRod=>"end_rod",McItem.Lever=>"lever",McItem.Redstone=>"redstone",McItem.RedstoneBlock=>"redstone_block",McItem.SheepMachine=>"sheep_machine",_=>"white"
    };
    internal static string Label(McItem item) => item switch
    {
        _ when AdventureItems.Label(item)!=null=>AdventureItems.Label(item)!,
        McItem.Mace=>"重锤",McItem.MaceDensity=>"重锤 · 致密 V",McItem.MaceBreach=>"重锤 · 破甲 IV",
        McItem.MaceWindI=>"重锤 · 风爆 I",McItem.MaceWindII=>"重锤 · 风爆 II",McItem.MaceWindIII=>"重锤 · 风爆 III",
        McItem.MaceDensityWind=>"重锤 · 致密 V／风爆 III",McItem.MaceBreachWind=>"重锤 · 破甲 IV／风爆 III",McItem.WindCharge=>"风弹",
        _ when MinecraftWeapons.IsSpear(item)=>new[]{"木矛","石矛","铜矛","铁矛","金矛","钻石矛","下界合金矛"}[MinecraftWeapons.Material(item)]
            +(MinecraftWeapons.Lunge(item)>0?" · 突进 "+new[]{"","I","II","III"}[MinecraftWeapons.Lunge(item)]:""),
        McItem.Sword=>"钻石剑",McItem.Shield=>"盾牌",McItem.Bow=>"弓",McItem.Tnt=>"TNT",
        McItem.Flint=>"打火石",McItem.Pearl=>"末影珍珠",McItem.Arrow=>"箭",
        McItem.Dirt=>"泥土",McItem.Stone=>"石头",McItem.ZombieEgg=>"僵尸刷怪蛋",McItem.CreeperEgg=>"苦力怕刷怪蛋",
        McItem.GoldenApple=>"金苹果",McItem.Pickaxe=>"钻石镐",McItem.Totem=>"不死图腾",McItem.Trident=>"三叉戟",
        McItem.Boat=>"橡木船",McItem.Piston=>"活塞",McItem.StickyPiston=>"黏性活塞",McItem.Observer=>"侦测器",McItem.EndRod=>"末地烛",McItem.Lever=>"拉杆",McItem.Redstone=>"红石粉",McItem.RedstoneBlock=>"红石块",McItem.SheepMachine=>"预制草羊机",_=>"空手"
    };
    internal static bool ContraptionItem(McItem item) => item>=McItem.Boat && item<=McItem.SheepMachine;
}
